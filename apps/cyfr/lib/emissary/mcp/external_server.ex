# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServer do
  @moduledoc """
  GenServer managing a connection to a single external MCP server.

  One process per active connection, keyed by `{name, athanor_id}`.
  Connects lazily on first access: a stateless `tools/list` probe under the
  current protocol revision, falling back to the legacy
  initialize → initialized handshake for third-party servers still on the
  older revision (see `connect/1`). Discovered tool definitions are cached.

  ## HTTP Transport

  Uses Streamable HTTP (JSON-RPC 2.0 over HTTP POST) as defined by the
  MCP spec. Each request gets a fresh HTTP request — no persistent connection.
  """

  use GenServer
  require Logger

  alias Emissary.MCP.Protocol

  @initialize_timeout_ms 15_000
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

  # The revision to offer a peer that turns out not to speak the current one.
  # `2025-03-26` rather than the newest legacy revision because it is the widest
  # common denominator among third-party servers still on the handshake.
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
  def get_tools(name, athanor_id) do
    case lookup(name, athanor_id) do
      {:ok, pid} -> GenServer.call(pid, :get_tools, @initialize_timeout_ms)
      {:error, _} = err -> err
    end
  end

  @doc """
  Call a tool on the external server.
  """
  def call_tool(name, athanor_id, tool_name, arguments) do
    case lookup(name, athanor_id) do
      {:ok, pid} -> GenServer.call(pid, {:call_tool, tool_name, arguments}, @call_timeout_ms)
      {:error, _} = err -> err
    end
  end

  @doc """
  Get the connection status of the external server.
  """
  def status(name, athanor_id) do
    case lookup(name, athanor_id) do
      {:ok, pid} -> GenServer.call(pid, :status)
      {:error, :not_running} -> :disconnected
    end
  end

  @doc """
  Reinitialize the connection (e.g., after config change).
  """
  def reinitialize(name, athanor_id) do
    case lookup(name, athanor_id) do
      {:ok, pid} -> GenServer.call(pid, :reinitialize, @initialize_timeout_ms)
      {:error, _} = err -> err
    end
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
    # unsealed to plaintext) and `raw_headers` may carry inline ones. OTP
    # prints `inspect(state)` in every GenServer crash/exit report, so both
    # are excluded from Inspect — a crashed call must not write bearer
    # tokens into the log stream.
    @derive {Inspect, except: [:headers, :raw_headers]}
    defstruct [
      :name,
      :url,
      :timeout_ms,
      :athanor_id,
      :server_info,
      :error,
      :last_init_attempt,
      # Which era this peer speaks. Determined once per connection and
      # cached: it is a property of the server, not of a request, and
      # re-probing on every call would double the traffic to a legacy peer
      # forever.
      :era,
      raw_headers: %{},
      headers: %{},
      status: :disconnected,
      tools: [],
      request_id: 0,
      # Detached upstream calls currently running: %{task_pid => monitor_ref}.
      in_flight: %{}
    ]
  end

  @impl true
  def init(config) do
    state = %State{
      name: config[:name],
      url: config[:url],
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
        # of state (resolved headers, masking material) and replies directly;
        # config (re)resolution stays serialized in the GenServer above. The
        # tool catalogue is dropped from the snapshot — the call doesn't read
        # it, and it would otherwise be copied into every task heap.
        snapshot = %{state | tools: [], in_flight: %{}}

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

               GenServer.reply(from, reply)
             end) do
          {:ok, task_pid} ->
            ref = Process.monitor(task_pid)
            # `from` rides along so an abnormal exit can still answer — see
            # the :DOWN clause.
            {:noreply, %{state | in_flight: Map.put(state.in_flight, task_pid, {ref, from})}}

          {:error, reason} ->
            {:reply, {:error, "External call failed to start: #{inspect(reason)}"}, state}
        end
    end
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
        headers: %{}
    }

    case do_initialize(state) do
      {:ok, state} -> {:reply, {:ok, state.status}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, task_pid, reason}, state) do
    # The task replies on its own way out, and its `rescue` covers a raise
    # — but not an exit: a supervisor shutdown or a kill leaves `from`
    # unanswered, and the caller then blocks for the whole two-minute call
    # timeout on a task that is already gone. Answer for it.
    case {reason, Map.get(state.in_flight, task_pid)} do
      {:normal, _} ->
        :ok

      {_reason, {_ref, from}} ->
        GenServer.reply(from, {:error, "External call did not complete"})

      _ ->
        :ok
    end

    {:noreply, %{state | in_flight: Map.delete(state.in_flight, task_pid)}}
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  defp max_in_flight,
    do: Application.get_env(:cyfr, :external_server_max_in_flight, @default_max_in_flight)

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

      {:error, reason} ->
        {:error, mask_credentials(reason, state)}
    end
  end

  # OTP crash reports and :sys.get_status print the full state — which
  # holds resolved credential header values. Redact both header maps so a
  # crashed server process cannot page a credential into the log.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, %State{} = state} ->
        {:state,
         %{
           state
           | headers: redact_values(state.headers),
             raw_headers: redact_values(state.raw_headers)
         }}

      other ->
        other
    end)
  end

  defp redact_values(map) when is_map(map), do: Map.new(map, fn {k, _} -> {k, "[REDACTED]"} end)
  defp redact_values(other), do: other

  @impl true
  def terminate(reason, state) do
    Logger.info("[ExternalServer] #{state.name} shutting down: #{inspect(reason)}")
    :ok
  end

  # ============================================================================
  # MCP Handshake
  # ============================================================================

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

    case Jason.encode(body) do
      {:ok, json_body} ->
        # Pin to the validated IP on EVERY request (not just at init), with the
        # original hostname preserved for SNI/Host. This both blocks SSRF and
        # closes the DNS-rebinding gap that connecting by hostname would reopen.
        # A private server (mcp-bridge on the compose network) is reachable
        # only when the operator named it in the private-egress allowlist.
        opts = [
          receive_timeout: state.timeout_ms,
          allow_private: :policy,
          # Enforced while the body streams in — the transfer aborts at the
          # ceiling, so a hostile peer cannot make this node buffer an
          # arbitrarily large body before a post-hoc check.
          max_response_bytes: @max_response_body_bytes
        ]

        case Cyfr.Network.pinned_request(:post, state.url, headers, json_body, opts) do
          {:ok, status, _headers, resp_body} when status in 200..299 ->
            with {:ok, parsed} <- parse_response(resp_body) do
              check_response_id(parsed, body)
            end

          {:error, {:response_too_large, _size, _max}} ->
            {:error, "Response too large (max 10MB)"}

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
          # generic message to the caller.
          {:error, reason} ->
            Logger.debug("[ExternalServer] request to #{state.name} failed: #{inspect(reason)}")
            {:error, "Request failed"}
        end

      {:error, _reason} ->
        {:error, "Request encoding failed"}
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

  # The JSON-RPC response out of an `text/event-stream` reply.
  #
  # Two things the previous line-at-a-time reading got wrong. SSE folds a
  # multi-line payload across consecutive `data:` lines within one event —
  # they are joined with newlines, not separate messages — so a pretty-
  # printed body was read as several fragments and all but the last thrown
  # away. And a conformant server may send progress events before the
  # result, separated by blank lines; the answer is the last EVENT, not the
  # last line.
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

  # `vault:` is the only credential reference. `secret:` is refused rather
  # than falling through to the literal clause below, which would send the
  # operator's reference text to a third party as the header value — a
  # request that silently fails to authenticate while looking like it tried.
  defp resolve_value("secret:" <> _name, athanor_id) do
    Logger.warning(
      "[ExternalServer] 'secret:' is not a credential reference — " <>
        "use vault:<entry name> (athanor=#{athanor_id})"
    )

    {:error, :unknown_credential_reference}
  end

  # A vault-backed header: `vault:<entry name>` resolves the entry's single
  # material field. Deliberately single-field — a header carries one value,
  # and picking silently from a bundle would smuggle the wrong credential
  # into the wrong header. Errors stay opaque outward, like secrets.
  defp resolve_value("vault:" <> entry_name, athanor_id) do
    case Sanctum.VaultReader.unseal_by_name(athanor_id, entry_name) do
      {:ok, fields} ->
        case Map.values(fields) do
          [value] ->
            {:ok, value}

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

  defp resolve_value(value, _athanor_id) when is_binary(value), do: {:ok, value}

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
        is_binary(raw) and String.starts_with?(raw, "vault:") -> with_bare_token(resolved)
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
    Cyfr.Network.validate_redirect_url(url,
      allow_private: :policy
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
