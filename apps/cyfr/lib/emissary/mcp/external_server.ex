# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServer do
  @moduledoc """
  GenServer managing a connection to a single external MCP server.

  One process per active connection, keyed by `{name, org_id, project_id}`.
  Performs the MCP handshake (initialize → initialized → tools/list) lazily
  on first access and caches discovered tool definitions.

  ## HTTP Transport

  Uses Streamlined HTTP (JSON-RPC 2.0 over HTTP POST) as defined by the
  MCP spec. Each request gets a fresh HTTP request — no persistent connection.
  """

  use GenServer
  require Logger

  alias Emissary.MCP.Protocol

  @default_timeout_ms 30_000
  @initialize_timeout_ms 15_000
  @registry Emissary.MCP.ExternalServerRegistry
  @version Mix.Project.config()[:version] || "0.1.0"

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
    org_id = Arca.QueryHelpers.normalize_org_id(config[:org_id])
    project_id = Arca.QueryHelpers.normalize_project_id(config[:project_id])

    # The Registry value is the digest of the config this process serves;
    # ExternalServerSupervisor.ensure_started/1 compares it against the
    # stored row's digest to reconcile config changes by restart.
    GenServer.start_link(__MODULE__, config,
      name:
        {:via, Registry,
         {@registry, {name, org_id, project_id},
          Emissary.MCP.ExternalServerSupervisor.config_digest(config)}}
    )
  end

  @doc """
  Get cached tool definitions from the external server.
  Triggers initialization if not yet connected.
  """
  def get_tools(name, org_id, project_id) do
    case lookup(name, org_id, project_id) do
      {:ok, pid} -> GenServer.call(pid, :get_tools, @initialize_timeout_ms)
      {:error, _} = err -> err
    end
  end

  @doc """
  Call a tool on the external server.
  """
  def call_tool(name, org_id, project_id, tool_name, arguments) do
    case lookup(name, org_id, project_id) do
      {:ok, pid} -> GenServer.call(pid, {:call_tool, tool_name, arguments}, @default_timeout_ms)
      {:error, _} = err -> err
    end
  end

  @doc """
  Get the connection status of the external server.
  """
  def status(name, org_id, project_id) do
    case lookup(name, org_id, project_id) do
      {:ok, pid} -> GenServer.call(pid, :status)
      {:error, :not_running} -> :disconnected
    end
  end

  @doc """
  Reinitialize the connection (e.g., after config change).
  """
  def reinitialize(name, org_id, project_id) do
    case lookup(name, org_id, project_id) do
      {:ok, pid} -> GenServer.call(pid, :reinitialize, @initialize_timeout_ms)
      {:error, _} = err -> err
    end
  end

  defp lookup(name, org_id, project_id) do
    org_id = Arca.QueryHelpers.normalize_org_id(org_id)
    project_id = Arca.QueryHelpers.normalize_project_id(project_id)

    case Registry.lookup(@registry, {name, org_id, project_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_running}
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(config) do
    state = %{
      name: config[:name],
      url: config[:url],
      raw_headers: config[:headers] || %{},
      headers: %{},
      timeout_ms: config[:timeout_ms] || @default_timeout_ms,
      org_id: Arca.QueryHelpers.normalize_org_id(config[:org_id]),
      project_id: Arca.QueryHelpers.normalize_project_id(config[:project_id]),
      status: :disconnected,
      tools: [],
      server_info: nil,
      request_id: 0,
      error: nil,
      last_init_attempt: nil,
      # Which era this peer speaks. Determined once per connection and cached:
      # it is a property of the server, not of a request, and re-probing on
      # every call would double the traffic to a legacy peer forever.
      era: nil
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
  def handle_call({:call_tool, tool_name, arguments}, _from, state) do
    state =
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

    if state.status != :ready do
      {:reply, {:error, "Server #{state.name} is not ready: #{state.error}"}, state}
    else
      {request_id, state} = next_request_id(state)

      body = %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "tools/call",
        "params" => %{
          "name" => tool_name,
          "arguments" => arguments || %{}
        }
      }

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

          {:reply,
           {:error,
            "#{state.name} asked for additional input, which external servers may not do."},
           state}

        {:ok, %{"result" => result}} ->
          {:reply, {:ok, mask_credentials(result, state)}, state}

        {:ok, %{"error" => error}} ->
          message = mask_credentials(error["message"] || inspect(error), state)
          {:reply, {:error, message}, state}

        {:legacy, state} ->
          {:reply, {:error, "#{state.name} changed protocol era mid-connection"}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
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
  def handle_info(msg, state) do
    Logger.warning("[ExternalServer] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

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

    with {:ok, resolved_headers} <-
           resolve_headers(state.raw_headers, state.org_id, state.project_id),
         state <- %{state | headers: resolved_headers},
         :ok <- validate_server_url(state.url),
         {:ok, tools, server_info, state} <- connect(state) do
      state = %{
        state
        | status: :ready,
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
      {:error, reason} ->
        state = %{state | status: :error, error: inspect(reason)}

        Logger.error("[ExternalServer] Failed to initialize #{state.name}: #{inspect(reason)}")

        {:error, reason, state}
    end
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

    body = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy_protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{
          "name" => "cyfr",
          "version" => @version
        }
      }
    }

    case http_post(state, body) do
      {:ok, %{"result" => result}} -> {:ok, result, state}
      {:ok, %{"error" => error}} -> {:error, error["message"] || inspect(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_initialized_notification(state) do
    body = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    }

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

    body = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => "tools/list",
      "params" => %{}
    }

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
        # allow_private mirrors validate_server_url: local/no-auth installs may
        # legitimately target localhost servers.
        opts = [
          receive_timeout: state.timeout_ms,
          allow_private: not Sanctum.auth_configured?()
        ]

        case Cyfr.Network.pinned_request(:post, state.url, headers, json_body, opts) do
          {:ok, status, _headers, resp_body} when status in 200..299 ->
            if byte_size(resp_body) > @max_response_body_bytes do
              {:error, "Response too large (max 10MB)"}
            else
              parse_response(resp_body)
            end

          {:ok, status, _headers, resp_body} ->
            # A 4xx while speaking the current revision is how a peer says it
            # cannot. The specification is explicit that the body has to be read
            # before falling back: a modern server also answers 4xx for an
            # unsupported version or a bad header, and those mean "retry
            # differently", not "you are talking to an older server".
            #
            # The body is inspected, never reflected — it may carry internal
            # diagnostics or credentials echoed back at us.
            if state.era == :modern and status in 400..499 and not modern_error?(resp_body) do
              {:legacy, state}
            else
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
      Protocol.meta_client_info_key() => %{"name" => "cyfr", "version" => @version},
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

  defp extract_sse_data(sse_body) do
    sse_body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&String.trim_leading(&1, "data:"))
    |> Enum.map(&String.trim/1)
    |> List.last() || ""
  end

  defp merge_headers(base, extra) when is_map(extra) do
    Enum.reduce(extra, base, fn {k, v}, acc ->
      [{String.downcase(to_string(k)), to_string(v)} | acc]
    end)
  end

  defp merge_headers(base, _), do: base

  # ============================================================================
  # Secret Resolution
  # ============================================================================

  @doc false
  def resolve_headers(headers, org_id, project_id) when is_map(headers) do
    resolved =
      Enum.reduce_while(headers, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case resolve_value(value, org_id, project_id) do
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

  def resolve_headers(_headers, _org_id, _project_id), do: {:ok, %{}}

  # The secrets plane is gone: a stale `secret:` header reference fails
  # closed with a server-side hint. Errors stay opaque outward.
  defp resolve_value("secret:" <> _name, org_id, _project_id) do
    Logger.warning(
      "[ExternalServer] secret: header references are no longer resolvable — " <>
        "rebind the header to vault:CONNECTION (org=#{org_id})"
    )

    {:error, :secret_ref_retired}
  end

  # A vault-backed header: `vault:<entry name>` resolves the entry's single
  # material field. Deliberately single-field — a header carries one value,
  # and picking silently from a bundle would smuggle the wrong credential
  # into the wrong header. Errors stay opaque outward, like secrets.
  defp resolve_value("vault:" <> entry_name, org_id, project_id) do
    case Sanctum.VaultReader.unseal_by_name(org_id, project_id, entry_name) do
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
        Logger.debug("[ExternalServer] vault header reference unresolved for org=#{org_id}")
        {:error, :vault_ref_unavailable}
    end
  end

  defp resolve_value(value, _org_id, _project_id) when is_binary(value), do: {:ok, value}

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
      allow_private: not Sanctum.auth_configured?()
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
