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

  @default_timeout_ms 30_000
  @initialize_timeout_ms 15_000
  @registry Emissary.MCP.ExternalServerRegistry
  @version Mix.Project.config()[:version] || "0.1.0"
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

    GenServer.start_link(__MODULE__, config,
      name: {:via, Registry, {@registry, {name, org_id, project_id}}}
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
      last_init_attempt: nil
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
        {:ok, %{"result" => result}} ->
          {:reply, {:ok, result}, state}

        {:ok, %{"error" => error}} ->
          {:reply, {:error, error["message"] || inspect(error)}, state}

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
    state = %{state | status: :disconnected, tools: [], server_info: nil, error: nil, headers: %{}}

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
    Logger.info("[ExternalServer] Initializing connection to #{state.name} at #{state.url}")
    state = %{state | last_init_attempt: System.monotonic_time(:millisecond)}

    with {:ok, resolved_headers} <- resolve_headers(state.raw_headers, state.org_id, state.project_id),
         state <- %{state | headers: resolved_headers},
         :ok <- validate_server_url(state.url),
         {:ok, init_result, state} <- send_initialize(state),
         :ok <- send_initialized_notification(state),
         {:ok, tools, state} <- send_tools_list(state) do
      server_info = init_result["serverInfo"]

      state = %{
        state
        | status: :ready,
          tools: tools,
          server_info: server_info,
          error: nil
      }

      Logger.info(
        "[ExternalServer] Connected to #{state.name}: #{length(tools)} tools discovered"
      )

      {:ok, state}
    else
      {:error, reason} ->
        state = %{state | status: :error, error: inspect(reason)}

        Logger.error(
          "[ExternalServer] Failed to initialize #{state.name}: #{inspect(reason)}"
        )

        {:error, reason, state}
    end
  end

  defp send_initialize(state) do
    {request_id, state} = next_request_id(state)

    body = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # HTTP Transport
  # ============================================================================

  defp http_post(state, body) do
    headers =
      [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}]
      |> merge_headers(state.headers)

    case Jason.encode(body) do
      {:ok, json_body} ->
        request = Finch.build(:post, state.url, headers, json_body)

        case Finch.request(request, Compendium.Finch, receive_timeout: state.timeout_ms) do
          {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
            if byte_size(resp_body) > @max_response_body_bytes do
              {:error, "Response too large (max 10MB)"}
            else
              parse_response(resp_body)
            end

          {:ok, %Finch.Response{status: status, body: resp_body}} ->
            {:error, "HTTP #{status}: #{String.slice(resp_body, 0, 200)}"}

          {:error, %Mint.TransportError{reason: reason}} ->
            {:error, "Connection error: #{inspect(reason)}"}

          {:error, reason} ->
            {:error, "Request failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "JSON encode error: #{inspect(reason)}"}
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
      {:error, _} -> {:error, "Invalid JSON response: #{String.slice(body, 0, 200)}"}
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

  defp resolve_headers(headers, org_id, project_id) when is_map(headers) do
    resolved =
      Enum.reduce_while(headers, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case resolve_value(value, org_id, project_id) do
          {:ok, resolved_value} -> {:cont, {:ok, Map.put(acc, key, resolved_value)}}
          {:error, reason} -> {:halt, {:error, "Failed to resolve header #{key}: #{reason}"}}
        end
      end)

    case resolved do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_headers(_headers, _org_id, _project_id), do: {:ok, %{}}

  defp resolve_value("secret:" <> secret_name, org_id, project_id) do
    # When auth is configured the scope is always `:org`. Single-user installs
    # trivially share secrets across their lone project, so `:org` is also
    # correct there (one tenant, one project).
    scope = :org

    ctx =
      Sanctum.Context.build(
        user_id: "system:external_mcp",
        org_id: org_id,
        project_id: project_id,
        permissions: [:secrets_read],
        scope: scope,
        authenticated: true
      )

    case Sanctum.Secrets.get(ctx, secret_name) do
      {:ok, value} -> {:ok, value}
      {:error, :not_found} -> {:error, "Secret '#{secret_name}' not found"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp resolve_value(value, _org_id, _project_id) when is_binary(value), do: {:ok, value}

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