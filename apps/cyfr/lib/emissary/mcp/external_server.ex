# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServer do
  @moduledoc """
  GenServer managing a connection to a single external MCP server.

  One process per active connection, keyed by `{name, athanor_id}`.
  Connects lazily on first access. Discovered tool definitions are cached.

  ## HTTP transport

  Uses Streamable HTTP (JSON-RPC 2.0 over HTTP POST) as defined by the
  MCP spec. Each request gets a fresh HTTP request — no persistent
  connection. Connecting is a stateless `tools/list` probe under the current
  protocol revision, falling back to the legacy initialize → initialized
  handshake for third-party servers still on the older revision (see
  `connect/1`).

  ## Stdio transport

  A stdio server's backends run on the MCP bridge. Connecting asks the
  controller (`Emissary.MCP.Bridge.sync/1`) to run this server's owner at
  its epoch and receives a grant; every request to the bridge's `/mcp` then
  carries a `Cyfr-Bridge-Auth` header signed with the grant's owner key
  over the exact body sent (`Cyfr.BridgeAuth.invoke_header/3`), with a
  fresh nonce and timestamp. The process holds the owner key and never an
  env value: the bridge masks backend credentials in what it answers.

  One member of the cell runs a backend, and the controller that answers
  `sync/1` is the one holding its claim; a member that holds none refuses
  the connection rather than starting a second copy, and says which case
  it is.

  A call the bridge refuses before running it is answered as follows:
  `stale_boot`, `epoch_ahead`, `unknown_owner` and `lapsed` sync again and
  retry the call once; `stale_epoch` re-reads the row, and a row whose epoch
  moved leaves this process in error until it is replaced. Stopping the
  process releases its owner on the bridge within 3 s.

  The tool catalogue is listed again whenever the controller issues a new
  grant or reports that the owner's catalogue changed — a backend that
  became ready after the sync answered, crashed or restarted — and a
  changed catalogue invalidates the athanor's cached external tool list and
  tells its subscribers (`Cyfr.Bus.mcp_servers/1`).
  """

  use GenServer
  require Logger

  alias Emissary.MCP.Protocol

  @initialize_timeout_ms 15_000
  # How long a caller waits for a connect, which for a stdio server includes
  # the bridge starting its backends.
  @connect_call_timeout_ms 60_000
  @retried_refusals ~w(stale_boot epoch_ahead unknown_owner lapsed)
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
  @default_max_in_flight 8
  @registry Emissary.MCP.ExternalServerRegistry

  # Offer 2025-03-26 to peers requiring the legacy handshake.
  @legacy_protocol_version "2025-03-26"

  # Matched in a pattern, so it has to be a compile-time literal — but it is
  # initialized from the one place the vocabulary is defined rather than written
  # out again here.
  @input_required Protocol.result_type(:input_required)

  @reinit_cooldown_ms 5_000
  # 10 MB
  @max_response_body_bytes 10_485_760

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(config) do
    name = config[:name]
    athanor_id = athanor_id!(config)

    # The Registry value is the digest of the config this process serves;
    # ExternalServerSupervisor.ensure_started/1 compares it against the
    # stored row's digest to reconcile config changes by restart.
    GenServer.start_link(__MODULE__, config,
      name:
        {:via, Registry,
         {@registry, {name, athanor_id},
          Emissary.MCP.ExternalServerSupervisor.config_digest(config)}}
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
              "Emissary.MCP.ExternalServer: config requires :athanor_id, got #{inspect(other)}"
    end
  end

  @doc """
  Get cached tool definitions from the external server.
  Triggers initialization if not yet connected.
  """
  @spec get_tools(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_tools(name, athanor_id) do
    case lookup(name, athanor_id) do
      {:ok, pid} -> call_server(pid, :get_tools, @connect_call_timeout_ms)
      {:error, _} = err -> err
    end
  end

  @doc """
  Call a tool on the external server.
  """
  def call_tool(name, athanor_id, tool_name, arguments) do
    case lookup(name, athanor_id) do
      {:ok, pid} -> call_tool(pid, tool_name, arguments)
      {:error, _} = err -> err
    end
  end

  @doc "Call a tool on the server process a caller already holds."
  @spec call_tool(pid(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(pid, tool_name, arguments) when is_pid(pid),
    do: call_server(pid, {:call_tool, tool_name, arguments}, @call_timeout_ms)

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
  Reinitialize the connection (e.g., after config change).
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
  # `Emissary.MCP.ExternalServerReconciler`, a changed row through
  # `Emissary.MCP.ExternalServerSupervisor.ensure_started/1`, and in a cell
  # a backend whose claim moved through `Emissary.MCP.Bridge` — so a call
  # in flight when one of those lands sees its process go. The contract of
  # `get_tools/2`, `call_tool/3` and `reinitialize/2`, and of
  # `Emissary.MCP.ExternalServers.ensure_started/2` above them, is a typed
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
    # unsealed to plaintext), `raw_headers` may carry inline ones and
    # `bridge` holds a stdio owner's key. OTP prints `inspect(state)` in
    # every GenServer crash/exit report, so all three are excluded from
    # Inspect — a crashed call must not write credentials into the log.
    @derive {Inspect, except: [:headers, :raw_headers, :bridge]}
    defstruct [
      :name,
      :url,
      :timeout_ms,
      :athanor_id,
      :server_id,
      :epoch,
      # The grant `Emissary.MCP.Bridge.sync/1` issued (stdio only).
      :bridge,
      :server_info,
      :error,
      :last_init_attempt,
      # Which era this peer speaks. Determined once per connection and
      # cached: it is a property of the server, not of a request, and
      # re-probing on every call would double the traffic to a legacy peer
      # forever.
      :era,
      transport: :http,
      raw_headers: %{},
      headers: %{},
      status: :disconnected,
      tools: [],
      request_id: 0,
      # Detached upstream calls currently running:
      # %{task_pid => {monitor_ref, from, caller_ref}}.
      in_flight: %{},
      # What each running call asked, so a refused one can be sent again:
      # %{task_pid => {tool_name, arguments, attempt}}.
      calls: %{}
    ]
  end

  # Exits are trapped so a stop — a vault change, a deleted row, an archived
  # athanor — runs `terminate/2`, which ends every upstream call still in
  # flight with the credentials this process resolved, and releases a
  # stdio server's owner on the bridge.
  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    state = %State{
      name: config[:name],
      url: config[:url],
      transport: config[:transport] || :http,
      server_id: config[:id],
      epoch: config[:epoch],
      raw_headers: config[:headers] || %{},
      timeout_ms:
        min(
          config[:timeout_ms] || Emissary.MCP.ExternalServers.default_timeout_ms(),
          @max_upstream_timeout_ms
        ),
      athanor_id: athanor_id!(config)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_tools, _from, %{status: :ready} = state) do
    {:reply, {:ok, state.tools}, state}
  end

  def handle_call(:get_tools, _from, %{status: :disconnected} = state) do
    case do_initialize(state) do
      {:ok, state} -> {:reply, {:ok, state.tools}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_tools, _from, %{status: :error} = state) do
    if can_reinit?(state) do
      case do_initialize(state) do
        {:ok, state} -> {:reply, {:ok, state.tools}, state}
        {:error, reason, state} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, state.error}, state}
    end
  end

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, from, state) do
    dispatch_call(state, from, {tool_name, arguments, 0})
  end

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
      state
      | status: :disconnected,
        tools: [],
        server_info: nil,
        error: nil,
        headers: %{},
        bridge: nil
    }

    case do_initialize(state) do
      {:ok, state} -> {:reply, {:ok, state.status}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  # Runs a call in a detached task, or answers why it cannot run. `attempt`
  # counts the times the bridge refused this call before running it.
  defp dispatch_call(state, from, {tool_name, arguments, _attempt} = call) do
    state = ensure_ready(state)

    cond do
      state.status != :ready ->
        {:reply, {:error, "Server #{state.name} is not ready: #{state.error}"}, state}

      map_size(state.in_flight) >= max_in_flight() ->
        {:reply,
         {:error,
          "Server #{state.name} is busy (#{max_in_flight()} calls in flight) — retry shortly"},
         state}

      true ->
        {request_id, state} = next_request_id(state)

        body =
          Emissary.MCP.Message.encode_request(request_id, "tools/call", %{
            "name" => tool_name,
            "arguments" => arguments || %{}
          })

        # The upstream HTTP round-trip runs OUTSIDE this process so one slow
        # server never head-of-line-blocks every other caller of the same
        # server for up to their full call timeout. The task gets a snapshot
        # of state (resolved headers, masking material, a stdio grant) and
        # replies directly; config (re)resolution stays serialized in the
        # GenServer above. The tool catalogue is dropped from the snapshot —
        # the call doesn't read it, and it would otherwise be copied into
        # every task heap.
        snapshot = %{state | tools: [], in_flight: %{}, calls: %{}}
        server = self()

        logger_metadata = Cyfr.LoggerContext.capture()

        case Task.Supervisor.start_child(Emissary.TaskSupervisor, fn ->
               Cyfr.LoggerContext.restore(logger_metadata)

               reply =
                 try do
                   dispatch_upstream_call(snapshot, body, tool_name)
                 rescue
                   e ->
                     # The exception's message can carry the upstream URL or
                     # a transport internal; the caller (a guest or the
                     # console) gets the tool's name only, the log the rest.
                     Logger.warning(
                       "[ExternalServer] call to #{tool_name} raised: #{Exception.message(e)}"
                     )

                     {:error, "External call failed for #{tool_name}"}
                 end

               case reply do
                 # Refused before it ran: the server decides what happens next.
                 {:bridge_refused, code, boot} ->
                   send(server, {:bridge_refused, self(), code, boot})

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

            {:noreply,
             %{
               state
               | in_flight: Map.put(state.in_flight, task_pid, {ref, from, caller_ref}),
                 calls: Map.put(state.calls, task_pid, call)
             }}

          {:error, reason} ->
            {:reply, {:error, "External call failed to start: #{inspect(reason)}"}, state}
        end
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

  # The bridge refused a call before running it.
  def handle_info({:bridge_refused, task_pid, code, boot}, state) do
    case Map.get(state.in_flight, task_pid) do
      {task_ref, from, caller_ref} ->
        Process.demonitor(task_ref, [:flush])
        Process.demonitor(caller_ref, [:flush])
        call = Map.fetch!(state.calls, task_pid)
        if code == "stale_boot" and is_binary(boot), do: Emissary.MCP.Bridge.boot_seen(boot)
        after_refusal(forget_call(state, task_pid), from, call, code)

      nil ->
        {:noreply, state}
    end
  end

  # The controller synced this server's owner again and issued a new grant.
  def handle_info({:bridge_owner, %{epoch: epoch} = grant}, %State{epoch: epoch} = state) do
    {:noreply, relist_tools(%{state | bridge: grant, url: grant.url})}
  end

  def handle_info({:bridge_owner, _grant_for_another_epoch}, state), do: {:noreply, state}

  # The bridge reports that this owner's tool catalogue changed.
  def handle_info({:bridge_tools_changed, epoch}, %State{epoch: epoch} = state) do
    {:noreply, relist_tools(state)}
  end

  def handle_info({:bridge_tools_changed, _another_epoch}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  defp forget_call(state, task_pid) do
    %{
      state
      | in_flight: Map.delete(state.in_flight, task_pid),
        calls: Map.delete(state.calls, task_pid)
    }
  end

  # A lifetime, generation or lease the grant no longer matches: sync again
  # and send the call once more.
  defp after_refusal(state, from, {tool, arguments, 0}, code) when code in @retried_refusals do
    state = %{state | status: :disconnected, bridge: nil, last_init_attempt: nil}

    case dispatch_call(state, from, {tool, arguments, 1}) do
      {:reply, reply, state} ->
        GenServer.reply(from, reply)
        {:noreply, state}

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  # The bridge runs a newer version of this owner. A row whose epoch moved
  # has been changed since this process started: it stays in error until
  # `Emissary.MCP.ExternalServerSupervisor.ensure_started/1` replaces it.
  defp after_refusal(state, from, _call, "stale_epoch") do
    ctx = Sanctum.Context.internal(athanor_id: state.athanor_id, scope: :athanor)

    state =
      case Arca.McpServerStorage.get_by_id(Sanctum.Context.actor(ctx), state.server_id) do
        {:ok, %{epoch: epoch}} when epoch == state.epoch ->
          state

        _moved_or_gone ->
          %{state | status: :error, error: "the server's configuration changed", bridge: nil}
      end

    GenServer.reply(
      from,
      {:error, "Server #{state.name} changed while the call was sent — retry"}
    )

    {:noreply, state}
  end

  defp after_refusal(state, from, _call, code) do
    GenServer.reply(from, {:error, "The MCP bridge refused the call to #{state.name} (#{code})"})
    {:noreply, state}
  end

  defp max_in_flight,
    do: Application.get_env(:cyfr, :external_server_max_in_flight, @default_max_in_flight)

  # A connected stdio server lists its tools again under its grant. A
  # refused or failed listing leaves the catalogue as it was: the next call
  # meets the refusal and recovers from it.
  defp relist_tools(%State{transport: :stdio, status: :ready, bridge: %{}} = state) do
    listing = %{state | timeout_ms: min(state.timeout_ms, @initialize_timeout_ms)}

    case send_tools_list(listing) do
      {:ok, tools, listed} when tools != state.tools ->
        Logger.info("[ExternalServer] #{state.name}: #{length(tools)} tools after a change")
        tools_changed(state.athanor_id)
        %{listed | timeout_ms: state.timeout_ms, tools: tools}

      {:ok, _same, listed} ->
        %{listed | timeout_ms: state.timeout_ms}

      _refused ->
        state
    end
  end

  defp relist_tools(state), do: state

  defp tools_changed(athanor_id) do
    Emissary.MCP.ExternalProvider.invalidate_external_tools_cache(
      Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)
    )

    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      Cyfr.Bus.mcp_servers(athanor_id),
      :mcp_servers_changed
    )
  end

  # Bring a not-yet-ready server up before dispatching, mirroring the
  # get_tools arms: disconnected always retries, error retries when the
  # backoff allows.
  defp ensure_ready(state) do
    case state.status do
      :ready ->
        state

      :disconnected ->
        case do_initialize(state) do
          {:ok, s} -> s
          {:error, _, s} -> s
        end

      :error ->
        if can_reinit?(state) do
          case do_initialize(state) do
            {:ok, s} -> s
            {:error, _, s} -> s
          end
        else
          state
        end
    end
  end

  # Runs in a Task: performs the upstream round-trip against a state
  # SNAPSHOT and never mutates server state.
  defp dispatch_upstream_call(state, body, tool_name) do
    case http_post(state, body) do
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
      {:ok, %{"result" => %{"resultType" => @input_required}}} ->
        Logger.warning(
          "[ExternalServer] #{state.name} returned input_required for #{tool_name}; refused"
        )

        {:error, "#{state.name} asked for additional input, which external servers may not do."}

      {:ok, %{"result" => result}} ->
        {:ok, mask_credentials(result, state)}

      {:ok, %{"error" => error}} ->
        {:error, mask_credentials(error["message"] || inspect(error), state)}

      {:legacy, _state} ->
        {:error, "#{state.name} changed protocol era mid-connection"}

      {:bridge_refused, _code, _boot} = refused ->
        refused

      {:error, reason} ->
        {:error, mask_credentials(reason, state)}
    end
  end

  # OTP crash reports and :sys.get_status print the state, the last message
  # and the exit reason — which can hold resolved credential header values
  # and a stdio owner's key.
  @impl true
  def format_status(status), do: Emissary.MCP.StatusRedaction.format_status(status)

  @impl true
  def terminate(reason, state) do
    Logger.info("[ExternalServer] #{state.name} shutting down: #{inspect(reason)}")

    for {task_pid, {task_ref, from, caller_ref}} <- state.in_flight do
      Process.demonitor(task_ref, [:flush])
      Process.demonitor(caller_ref, [:flush])
      Process.exit(task_pid, :kill)
      GenServer.reply(from, {:error, {:uncertain, "Server #{state.name} stopped mid-call"}})
    end

    if state.transport == :stdio, do: Emissary.MCP.Bridge.release(owner(state))

    :ok
  end

  defp owner(state),
    do: %{athanor_id: state.athanor_id, server_id: state.server_id, epoch: state.epoch}

  # ============================================================================
  # MCP Handshake
  # ============================================================================

  # A stdio server connects through the bridge: a grant for its owner, then
  # a signed `tools/list`. A grant the bridge stops honouring between the
  # two (it restarted, or the lease lapsed) is asked for once more.
  defp do_initialize(%State{transport: :stdio} = state) do
    Logger.info("[ExternalServer] Connecting to #{state.name} through the MCP bridge")
    state = %{state | last_init_attempt: System.monotonic_time(:millisecond), era: :modern}
    stdio_connect(state, 0)
  end

  defp do_initialize(state) do
    Logger.info("[ExternalServer] Connecting to #{state.name} at #{state.url}")
    state = %{state | last_init_attempt: System.monotonic_time(:millisecond)}

    # The handshake runs inside handle_call while callers wait only
    # @initialize_timeout_ms — clamp the wire timeout to match, so a
    # stalling upstream cannot head-of-line-block the server process for
    # the full per-call budget. The operator's timeout applies to tool
    # calls, which run detached.
    handshake_timeout = min(state.timeout_ms, @initialize_timeout_ms)
    call_timeout = state.timeout_ms

    # Headers are resolved before the `with`, not inside it: `with` does not
    # export its bindings to `else`, so the failure arm masked with the
    # *outer* state, whose `headers` is the struct's empty default (and is
    # reset to empty on every `:reinitialize`). `sensitive_header_values/1`
    # requires a resolved binary per key, found none, and masked nothing — so
    # on a first connect, an upstream that echoed the Authorization header
    # into its error body carried it out whole through `state.error`.
    case resolve_headers(state.raw_headers, state.athanor_id) do
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
              server_info: server_info,
              error: nil
          }

          Logger.info(
            "[ExternalServer] Connected to #{state.name} (#{state.era}): " <>
              "#{length(tools)} tools discovered"
          )

          {:ok, state}
        else
          {:error, reason} -> fail_initialize(state, reason)
        end
    end
  end

  # The `else` arms see the state this function was called with: no grant,
  # and the operator's call timeout.
  defp stdio_connect(state, attempt) do
    with {:ok, grant} <- Emissary.MCP.Bridge.sync(owner(state)),
         granted = %{
           state
           | bridge: grant,
             url: grant.url,
             timeout_ms: min(state.timeout_ms, @initialize_timeout_ms)
         },
         {:ok, tools, connected} <- send_tools_list(granted) do
      Logger.info(
        "[ExternalServer] Connected to #{state.name}: #{length(tools)} tools discovered"
      )

      {:ok, %{connected | timeout_ms: state.timeout_ms, status: :ready, tools: tools, error: nil}}
    else
      {:error, {:bridge_refused, code, _boot}} when code in @retried_refusals and attempt == 0 ->
        stdio_connect(state, 1)

      {:error, reason} ->
        fail_initialize(%{state | bridge: nil}, bridge_reason(reason))

      {:legacy, _state} ->
        fail_initialize(%{state | bridge: nil}, "the MCP bridge refused the request")
    end
  end

  defp bridge_reason({:bridge_refused, code, _boot}), do: "the MCP bridge refused (#{code})"
  defp bridge_reason(:bridge_not_configured), do: "no MCP bridge is configured"
  defp bridge_reason(:bridge_unavailable), do: "the MCP bridge is unavailable"
  defp bridge_reason(:control_plane_lost), do: "this server does not own its control plane"
  defp bridge_reason(:capacity), do: "the MCP bridge has no free backend slots"

  defp bridge_reason(:claimed_elsewhere),
    do: "another member of the cell holds this server's backends"

  defp bridge_reason(:claim_unavailable),
    do: "which member holds this server's backends could not be read"

  defp bridge_reason({:pool_share, limit}),
    do: "this athanor already runs its share of the MCP bridge (#{limit} backends)"

  defp bridge_reason({:person_share, limit}),
    do:
      "the member who created this server already runs their share of the MCP bridge " <>
        "(#{limit} backends, across every athanor)"

  defp bridge_reason({:control_too_large, limit}),
    do: "this server's backends and their env exceed what one sync may carry (#{limit} bytes)"

  defp bridge_reason({:env_unresolved, backend, name}),
    do: "backend '#{backend}' env #{name} does not resolve to a single-field vault entry"

  defp bridge_reason(reason), do: reason

  # `state.error` surfaces to callers and the status view — the same egress
  # rule as results: mask the credentials this plane injected before a
  # transport exception that echoed them can carry one out. The log gets the
  # masked sentence too; the credential is never the diagnostic part.
  defp fail_initialize(state, reason) do
    masked = mask_credentials(inspect(reason), state)
    state = %{state | status: :error, error: masked}

    Logger.error("[ExternalServer] Failed to initialize #{state.name}: #{masked}")

    {:error, reason, state}
  end

  # Try the current protocol first; fall back to the handshake only when the
  # answer says the peer cannot speak it.
  #
  # The fallback exists for third-party servers, which are on their own release
  # cadence and mostly still expect `initialize`. It is not a compatibility
  # shim for anything CYFR ships: `apps/mcp-bridge` speaks the current revision,
  # so the bundled deployment never takes this path. The specification
  # prescribes exactly this probe — attempt a modern request, and read the body
  # of a `400` before concluding the peer is legacy, because a modern server
  # also answers `400` for an unsupported version or a bad header.
  defp connect(state) do
    case send_tools_list(%{state | era: :modern}) do
      {:ok, tools, state} ->
        {:ok, tools, nil, state}

      {:legacy, state} ->
        Logger.info("[ExternalServer] #{state.name} speaks a pre-2026-07-28 revision")
        legacy_connect(%{state | era: :legacy})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp legacy_connect(state) do
    with {:ok, init_result, state} <- send_initialize(state),
         :ok <- send_initialized_notification(state),
         {:ok, tools, state} <- send_tools_list(state) do
      {:ok, tools, init_result["serverInfo"], state}
    else
      # A legacy peer has no fall-forward; a second `:legacy` here would mean the
      # handshake itself was refused, which is a failure rather than an era.
      {:legacy, state} -> {:error, "#{state.name} refused both protocol eras"}
      other -> other
    end
  end

  defp send_initialize(state) do
    {request_id, state} = next_request_id(state)

    body =
      Emissary.MCP.Message.encode_request(request_id, "initialize", %{
        "protocolVersion" => @legacy_protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{
          "name" => "cyfr",
          "version" => Cyfr.Version.current()
        }
      })

    case http_post(state, body) do
      {:ok, %{"result" => result}} -> {:ok, result, state}
      {:ok, %{"error" => error}} -> {:error, error["message"] || inspect(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_initialized_notification(state) do
    body = Emissary.MCP.Message.encode_notification("notifications/initialized")

    case http_post(state, body) do
      # Notifications may return empty or accepted
      {:ok, _} -> :ok
      # Some servers don't respond to notifications
      {:error, :empty_response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_tools_list(state) do
    {request_id, state} = next_request_id(state)

    body = Emissary.MCP.Message.encode_request(request_id, "tools/list", %{})

    case http_post(state, body) do
      {:ok, %{"result" => %{"tools" => tools}}} ->
        {:ok, tools, state}

      {:ok, %{"result" => result}} ->
        # Some servers return tools at top level
        {:ok, Map.get(result, "tools", []), state}

      {:ok, %{"error" => error}} ->
        {:error, error["message"] || inspect(error)}

      {:legacy, state} ->
        {:legacy, state}

      {:bridge_refused, _code, _boot} = refused ->
        {:error, refused}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # HTTP Transport
  # ============================================================================

  defp http_post(state, body) do
    body = maybe_add_meta(body, state.era)

    headers =
      [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}]
      |> Enum.concat(protocol_headers(body, state.era, state.tools))
      |> merge_headers(state.headers)

    with {:ok, json_body} <- Jason.encode(body),
         {:ok, headers} <- sign(state, headers, json_body) do
      post_encoded(state, body, headers, json_body)
    else
      {:error, {:invalid_field, _}} -> {:error, "Request signing failed"}
      {:error, _reason} -> {:error, "Request encoding failed"}
    end
  end

  # A stdio server's request carries the owner's signature over the exact
  # bytes sent, with a nonce and timestamp of its own.
  defp sign(%State{transport: :stdio, bridge: %{} = grant} = state, headers, json_body) do
    invoke = %{
      athanor: state.athanor_id,
      server: state.server_id,
      generation: grant.generation,
      epoch: grant.epoch,
      boot: grant.boot,
      ts: System.os_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    }

    with {:ok, header} <- Cyfr.BridgeAuth.invoke_header(grant.owner_key, invoke, json_body) do
      {:ok, [{"cyfr-bridge-auth", header} | headers]}
    end
  end

  defp sign(%State{transport: :stdio}, _headers, _json_body),
    do: {:error, {:invalid_field, :grant}}

  defp sign(_state, headers, _json_body), do: {:ok, headers}

  defp post_encoded(state, body, headers, json_body) do
    # Pin to the validated IP on EVERY request (not just at init), with the
    # original hostname preserved for SNI/Host. This both blocks SSRF and
    # closes the DNS-rebinding gap that connecting by hostname would reopen.
    # A private server (mcp-bridge on the compose network) is reachable
    # only when the operator named it in the private-egress allowlist.
    opts = [
      receive_timeout: state.timeout_ms,
      private_policy: :operator,
      # Enforced while the body streams in — the transfer aborts at the
      # ceiling, so a hostile peer cannot make this node buffer an
      # arbitrarily large body before a post-hoc check.
      max_response_bytes: @max_response_body_bytes
    ]

    case Sanctum.Egress.pinned_request(:post, state.url, headers, json_body, opts) do
      {:ok, status, _headers, resp_body} when status in 200..299 ->
        with {:ok, parsed} <- parse_response(resp_body) do
          check_response_id(parsed, body)
        end

      {:error, {:response_too_large, _size, _max}} ->
        {:error, "Response too large (max 10MB)"}

      {:ok, status, resp_headers, resp_body} when state.transport == :stdio ->
        bridge_refusal(status, resp_headers, resp_body)

      {:ok, status, _headers, resp_body} ->
        # A 4xx while speaking the current revision is how a peer says it
        # cannot. The specification is explicit that the body has to be read
        # before falling back: a modern server also answers 4xx for an
        # unsupported version or a bad header, and those mean "retry
        # differently", not "you are talking to an older server".
        #
        # The body is inspected, never reflected — it may carry internal
        # diagnostics or credentials echoed back at us.
        cond do
          # An auth rejection is never an era signal: a legacy retry
          # re-sends the same refused credential, wastes a round-trip,
          # and logs "speaks a pre-2026 revision" about a server whose
          # only complaint is the bearer token. Say what it is.
          status in [401, 403] ->
            {:error,
             "HTTP #{status} — the server refused the configured " <>
               "credentials; check the registered Authorization header"}

          state.era == :modern and status in 400..499 and not modern_error?(resp_body) ->
            {:legacy, state}

          true ->
            {:error, "HTTP #{status}"}
        end

      # SSRF/DNS validation failures are safe, descriptive strings.
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      # Transport/connection failure — log detail internally, surface a
      # generic message to the caller. Whether the request reached the
      # server is not known from here.
      {:error, reason} ->
        Logger.debug("[ExternalServer] request to #{state.name} failed: #{inspect(reason)}")
        {:error, {:uncertain, "Request failed"}}
    end
  end

  # The bridge refuses before anything runs: a bad signature (401), or a
  # request that names another lifetime, version, lease or nonce (409, 503).
  # Anything else is a JSON-RPC error the MCP layer answered.
  defp bridge_refusal(401, _headers, _body),
    do: {:error, "the MCP bridge refused this server's signature"}

  defp bridge_refusal(status, headers, body) when status in [409, 503] do
    case Jason.decode(body) do
      {:ok, %{"error" => code}} when is_binary(code) ->
        {:bridge_refused, code, Emissary.MCP.Bridge.boot_header(headers)}

      _ ->
        {:error, "HTTP #{status}"}
    end
  end

  defp bridge_refusal(status, _headers, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) ->
        {:error, "HTTP #{status}: #{message}"}

      _ ->
        {:error, "HTTP #{status}"}
    end
  end

  # Per-request metadata. There is no handshake in this revision, so a request
  # that omits it is malformed rather than merely terse.
  defp maybe_add_meta(body, :modern) do
    params = Map.get(body, "params") || %{}

    meta = %{
      Protocol.meta_protocol_version_key() => Protocol.version(),
      Protocol.meta_client_info_key() => %{"name" => "cyfr", "version" => Cyfr.Version.current()},
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
      name -> [{Protocol.name_header(), encode_header_value(name)} | base]
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
           encode_header_value(to_header_value(value))}
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

  # A value that cannot travel as a plain header goes in the specification's
  # Base64 sentinel, which the receiving server decodes before comparing.
  defp encode_header_value(value) do
    safe? =
      value != "" and value == String.trim(value) and
        not String.starts_with?(value, "=?base64?") and
        String.to_charlist(value) |> Enum.all?(&(&1 >= 0x20 and &1 <= 0x7E))

    if safe?, do: value, else: "=?base64?" <> Base.encode64(value) <> "?="
  end

  # A modern server answers 4xx with a JSON-RPC error for an unsupported version,
  # a missing capability or a header mismatch. Seeing one means the peer is
  # current and the request was wrong — retry differently rather than fall back.
  defp modern_error?(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code}}} when is_integer(code) -> code <= -32020
      _ -> false
    end
  end

  # A response speaks only for the request whose id it carries: a peer
  # answering some other id — or an SSE stream whose last event was not
  # the reply — must not be folded into this call's result. A missing or
  # null id passes (JSON-RPC error responses may carry id: null); a
  # DIFFERENT id never does.
  defp check_response_id(parsed, %{"id" => request_id}) when is_map(parsed) do
    case Map.get(parsed, "id") do
      ^request_id -> {:ok, parsed}
      nil -> {:ok, parsed}
      other -> {:error, "Response id #{inspect(other)} answers a different request"}
    end
  end

  defp check_response_id(parsed, _notification), do: {:ok, parsed}

  defp parse_response(""), do: {:error, :empty_response}

  defp parse_response(body) when is_binary(body) do
    # Handle SSE-wrapped responses (some MCP servers use text/event-stream)
    body =
      if String.starts_with?(body, "event:") or String.starts_with?(body, "data:") do
        extract_sse_data(body)
      else
        body
      end

    case Jason.decode(body) do
      {:ok, parsed} -> {:ok, parsed}
      # Don't reflect the raw body — it may carry internal diagnostics.
      {:error, _} -> {:error, "Invalid JSON response"}
    end
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
        # keystore, not cons: an operator's content-type must REPLACE the
        # client's base header — prepending sent both, and which one the
        # upstream honored was its choice, not ours.
        List.keystore(acc, name, 0, {name, value})
      else
        Logger.warning(
          "[ExternalServer] refusing header #{inspect(name)}: a header name must be an HTTP " <>
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

  @doc false
  def resolve_headers(headers, athanor_id) when is_map(headers) do
    resolved =
      Enum.reduce_while(headers, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case resolve_value(value, athanor_id) do
          {:ok, resolved_value} ->
            {:cont, {:ok, Map.put(acc, key, resolved_value)}}

          # Report only the header name (caller-supplied config), never the
          # referenced secret name or the underlying error — that would let a
          # caller enumerate which secrets exist.
          {:error, _reason} ->
            {:halt, {:error, "Failed to resolve header '#{key}'"}}
        end
      end)

    case resolved do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_headers(_headers, _athanor_id), do: {:ok, %{}}

  # A vault-backed header (`Emissary.MCP.VaultRef.template/1`) resolves the
  # entry's single material field. Deliberately single-field — a header
  # carries one value, and picking silently from a bundle would smuggle the
  # wrong credential into the wrong header. Errors stay opaque outward, like
  # secrets.
  defp resolve_value(value, athanor_id) when is_binary(value) do
    case Emissary.MCP.VaultRef.classify(value) do
      {:vault, template} -> resolve_template(template, athanor_id)
      :unresolved -> {:error, :unresolved_ref}
      :literal -> {:ok, value}
    end
  end

  defp resolve_template(%{name: entry_name} = template, athanor_id) do
    case Sanctum.VaultReader.unseal_by_name(athanor_id, entry_name) do
      {:ok, fields} ->
        case Map.values(fields) do
          [value] ->
            {:ok, Emissary.MCP.VaultRef.render(template, value)}

          _ ->
            Logger.debug(
              "[ExternalServer] vault header ref must name a single-field entry, " <>
                "got #{map_size(fields)} fields"
            )

            {:error, :vault_ref_ambiguous}
        end

      {:error, _} ->
        Logger.debug(
          "[ExternalServer] vault header reference unresolved for athanor=#{athanor_id}"
        )

        {:error, :vault_ref_unavailable}
    end
  end

  # ============================================================================
  # Credential masking
  # ============================================================================

  # An upstream server can echo request headers back in its result (debug
  # endpoints, error bodies, proxies). External responses never pass through
  # the executor's SecretMasker, so the credentials THIS plane injected are
  # masked here: every resolved `vault:` header value plus the value of any
  # credential-shaped literal header.
  @doc false
  def mask_credentials(term, state) do
    case sensitive_header_values(state) do
      [] -> term
      values -> mask_values(term, values)
    end
  end

  defp sensitive_header_values(state) do
    state.raw_headers
    |> Enum.flat_map(fn {key, raw} ->
      resolved = Map.get(state.headers, key)

      cond do
        not is_binary(resolved) -> []
        Emissary.MCP.VaultRef.vault_ref?(raw) -> with_bare_token(resolved)
        credential_shaped_header?(key) -> with_bare_token(resolved)
        true -> []
      end
    end)
    # Too-short values would mangle unrelated text (e.g. "gzip")
    |> Enum.filter(&(byte_size(&1) >= 8))
    |> Enum.uniq()
  end

  # "Bearer sk-..." should also mask the bare token after the scheme prefix.
  defp with_bare_token(value) do
    case String.split(value, " ") do
      [_] -> [value]
      parts -> [value, List.last(parts)]
    end
  end

  defp credential_shaped_header?(key) do
    k = key |> to_string() |> String.downcase()

    k in ["authorization", "proxy-authorization", "cookie", "x-api-key"] or
      String.contains?(k, "token") or String.contains?(k, "secret") or
      String.contains?(k, "auth") or String.contains?(k, "key")
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
