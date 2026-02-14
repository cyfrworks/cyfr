defmodule Opus.HttpStreamHandler do
  @moduledoc """
  Polling-based streaming HTTP handler for WASM components.

  Provides `cyfr:http/stream` host functions that enable WASM components to
  consume streaming HTTP responses (e.g., Server-Sent Events from OpenAI).

  ## Interface

      cyfr:http/stream.request(json) -> handle_id (string)
      cyfr:http/stream.read(handle_id) -> chunk_json (string)
      cyfr:http/stream.close(handle_id) -> result (string)

  ## Flow

  1. WASM calls `stream.request(json)` — host starts async HTTP request, returns handle ID
  2. WASM calls `stream.read(handle)` in a loop — returns `{"data": "...", "done": false}`
  3. When stream ends: `{"data": "", "done": true}`
  4. WASM calls `stream.close(handle)` — host cleans up resources

  ## Security

  All the same policy enforcement as `cyfr:http/fetch` applies:
  - Domain allowlisting, method checking, SSRF prevention
  - Rate limiting (each stream.request counts as one request)
  - Cumulative response size tracked against `max_response_size`
  - Max concurrent streams per execution (default 3)
  - Auto-cleanup after 60s timeout or on execution completion
  """

  require Logger

  alias Sanctum.{Context, Policy}
  alias Opus.{HttpHandler, PolicyEnforcer}

  @stream_timeout_ms 60_000
  @max_concurrent_streams 3

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:http/stream` host functions.

  Returns a map with `request`, `read`, and `close` functions.
  """
  @spec build_stream_imports(Policy.t(), Context.t(), String.t()) :: map()
  def build_stream_imports(%Policy{} = policy, %Context{} = ctx, component_ref) do
    # Create a unique execution ref for cache-based stream tracking
    exec_ref = create_registry()

    %{
      "cyfr:http/streaming@0.1.0" => %{
        "request" => {:fn, fn json_req ->
          stream_request(json_req, policy, ctx, component_ref, exec_ref)
        end},
        "read" => {:fn, fn handle_id ->
          stream_read(handle_id, exec_ref, policy)
        end},
        "close" => {:fn, fn handle_id ->
          stream_close(handle_id, exec_ref)
        end}
      }
    }
  end

  @doc """
  Clean up all streams for an execution ref. Call this when execution completes.
  """
  @spec cleanup_registry(String.t()) :: :ok
  def cleanup_registry(exec_ref) do
    streams = Arca.Cache.match({:http_stream, exec_ref, :_})

    for {{:http_stream, ^exec_ref, _handle_id} = key, stream_state} <- streams do
      cleanup_stream(stream_state)
      Arca.Cache.invalidate(key)
    end

    :ok
  end

  # ============================================================================
  # Private: Stream Operations
  # ============================================================================

  defp create_registry do
    Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end

  defp stream_request(json_request, policy, ctx, component_ref, exec_ref) do
    # Check concurrent stream limit
    stream_count =
      Arca.Cache.match({:http_stream, exec_ref, :_})
      |> length()

    if stream_count >= @max_concurrent_streams do
      encode_error(:stream_limit, "Maximum concurrent streams (#{@max_concurrent_streams}) exceeded")
    else
      with {:ok, request} <- parse_stream_request(json_request),
           :ok <- validate_stream_method(policy, request.method),
           :ok <- validate_stream_domain(policy, request.url),
           :ok <- check_stream_rate_limit(policy, ctx, component_ref),
           {:ok, ip} <- HttpHandler.resolve_and_validate_ip(request.hostname) do
        start_stream(request, ip, exec_ref, component_ref)
      else
        {:error, type, message} ->
          encode_error(type, message)
      end
    end
  end

  defp stream_read(handle_id, exec_ref, policy) do
    case Arca.Cache.get({:http_stream, exec_ref, handle_id}) do
      {:ok, stream_state} ->
        # Check timeout
        elapsed = System.monotonic_time(:millisecond) - stream_state.started_at

        if elapsed > @stream_timeout_ms do
          cleanup_stream(stream_state)
          Arca.Cache.invalidate({:http_stream, exec_ref, handle_id})
          encode_error(:timeout, "Stream timed out after #{div(@stream_timeout_ms, 1000)}s")
        else
          read_from_stream(handle_id, stream_state, exec_ref, policy)
        end

      :miss ->
        encode_error(:invalid_handle, "Unknown stream handle: #{handle_id}")
    end
  end

  defp stream_close(handle_id, exec_ref) do
    case Arca.Cache.get({:http_stream, exec_ref, handle_id}) do
      {:ok, stream_state} ->
        cleanup_stream(stream_state)
        Arca.Cache.invalidate({:http_stream, exec_ref, handle_id})
        Jason.encode!(%{"ok" => true})

      :miss ->
        Jason.encode!(%{"ok" => true})
    end
  end

  # ============================================================================
  # Private: Stream Lifecycle
  # ============================================================================

  defp start_stream(request, ip_string, exec_ref, component_ref) do
    handle_id = generate_handle_id()

    case parse_method_atom(request.method) do
      {:error, message} ->
        encode_error(:method_blocked, message)

      {:ok, method_atom} ->
        # Create a buffer agent to collect chunks
        {:ok, buffer} = Agent.start_link(fn -> %{chunks: [], done: false} end)

        # Start an unlinked process to perform the streaming request.
        # NOTE: We use spawn (not Task.async or spawn_link) because this code
        # runs inside the Wasmex.Components GenServer. Task.async sends a
        # completion message that crashes handle_info/2, and spawn_link sends
        # an EXIT signal on process termination — both unhandled by Wasmex.
        pid = spawn(fn ->
          perform_streaming_request(request, method_atom, ip_string, buffer, component_ref)
        end)

        stream_state = %{
          task_pid: pid,
          buffer: buffer,
          started_at: System.monotonic_time(:millisecond),
          cumulative_size: 0,
          component_ref: component_ref
        }

        Arca.Cache.put({:http_stream, exec_ref, handle_id}, stream_state, @stream_timeout_ms)

        Jason.encode!(%{"handle" => handle_id})
    end
  end

  defp perform_streaming_request(request, method_atom, _ip_string, buffer, _component_ref) do
    # Note: We validated DNS resolves to a public IP (SSRF protection) in
    # stream_request/5 but do NOT pin the connection to that IP, as IP pinning
    # breaks TLS SNI for services behind CDNs (e.g. OpenAI via Cloudflare).
    # Same approach as HttpHandler.build_req_opts/3.
    req_opts = [
      method: method_atom,
      url: request.url,
      headers: request.headers,
      body: if(request.body != "", do: request.body, else: nil),
      redirect: false,
      receive_timeout: @stream_timeout_ms,
      into: :self
    ]

    case Req.request(req_opts) do
      {:ok, response} ->
        # Collect streaming chunks
        collect_stream_chunks(response, buffer)

      {:error, _exception} ->
        Agent.update(buffer, fn state -> %{state | done: true} end)
    end
  end

  defp collect_stream_chunks(response, buffer) do
    # Req's `into: :self` sends raw Mint transport messages (e.g. {:ssl, socket, data}).
    # We must use Req.parse_message/2 to decode them into {:ok, chunks} where
    # chunks contain {:data, binary} or :done.
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, chunks} ->
            Enum.each(chunks, fn
              {:data, data} ->
                Agent.update(buffer, fn state ->
                  %{state | chunks: state.chunks ++ [data]}
                end)

              :done ->
                Agent.update(buffer, fn state -> %{state | done: true} end)

              _other ->
                :ok
            end)

            # Continue if not done
            if Enum.member?(chunks, :done) do
              :ok
            else
              collect_stream_chunks(response, buffer)
            end

          {:error, _reason} ->
            Agent.update(buffer, fn state -> %{state | done: true} end)
            :error

          :unknown ->
            # Message not for this response, keep waiting
            collect_stream_chunks(response, buffer)
        end

    after
      @stream_timeout_ms ->
        Agent.update(buffer, fn state -> %{state | done: true} end)
        :timeout
    end
  end

  defp read_from_stream(handle_id, stream_state, exec_ref, policy) do
    # Atomically pop the first chunk to avoid race with the streaming process
    # appending new chunks between a get and a separate update.
    case Agent.get_and_update(stream_state.buffer, fn state ->
      case state.chunks do
        [chunk | rest] -> {{:chunk, chunk}, %{state | chunks: rest}}
        [] -> {{:empty, state.done}, state}
      end
    end) do
      {:empty, true} ->
        Jason.encode!(%{"data" => "", "done" => true})

      {:empty, false} ->
        Jason.encode!(%{"data" => "", "done" => false})

      {:chunk, chunk} ->
        # Track cumulative response size
        new_cumulative = stream_state.cumulative_size + byte_size(chunk)

        if new_cumulative > policy.max_response_size do
          cleanup_stream(stream_state)
          Arca.Cache.invalidate({:http_stream, exec_ref, handle_id})
          encode_error(:response_too_large,
            "Stream response (#{new_cumulative} bytes) exceeds limit (#{policy.max_response_size} bytes)")
        else
          # Update cumulative size in cache
          updated_state = %{stream_state | cumulative_size: new_cumulative}
          Arca.Cache.put({:http_stream, exec_ref, handle_id}, updated_state, @stream_timeout_ms)

          Jason.encode!(%{"data" => chunk, "done" => false})
        end
    end
  end

  defp cleanup_stream(stream_state) do
    # Stop the buffer agent
    try do
      Agent.stop(stream_state.buffer, :normal)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Kill the streaming process if still running
    if is_pid(stream_state[:task_pid]) and Process.alive?(stream_state.task_pid) do
      Process.exit(stream_state.task_pid, :kill)
    end
  end

  # ============================================================================
  # Private: Request Parsing & Validation
  # ============================================================================

  defp parse_stream_request(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"method" => method, "url" => url} = req} ->
        uri = URI.parse(url)
        hostname = uri.host

        if is_nil(hostname) or hostname == "" do
          {:error, :http_error, "Invalid URL: missing hostname"}
        else
          {:ok,
           %{
             method: String.upcase(method),
             url: url,
             hostname: hostname,
             headers: parse_headers(req["headers"]),
             body: req["body"] || ""
           }}
        end

      {:ok, _} ->
        {:error, :http_error, "Invalid request: must include 'method' and 'url'"}

      {:error, _} ->
        {:error, :http_error, "Invalid JSON request"}
    end
  end

  defp parse_headers(nil), do: []
  defp parse_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end
  defp parse_headers(headers) when is_list(headers), do: headers
  defp parse_headers(_), do: []

  defp validate_stream_domain(policy, url) do
    uri = URI.parse(url)
    domain = uri.host || ""

    case PolicyEnforcer.check_domain(policy, domain) do
      :ok -> :ok
      {:error, msg} -> {:error, :domain_blocked, msg}
    end
  end

  defp validate_stream_method(policy, method) do
    case PolicyEnforcer.check_method(policy, method) do
      :ok -> :ok
      {:error, msg} -> {:error, :method_blocked, msg}
    end
  end

  defp check_stream_rate_limit(policy, ctx, component_ref) do
    case Policy.check_rate_limit(policy, ctx, component_ref) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        {:error, :rate_limited,
         "Rate limit exceeded. Retry after #{div(retry_after, 1000)}s"}
    end
  end

  @valid_http_methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "DELETE" => :delete,
    "PATCH" => :patch,
    "HEAD" => :head,
    "OPTIONS" => :options
  }

  defp parse_method_atom(method) do
    case Map.fetch(@valid_http_methods, method) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "Unsupported HTTP method: #{method}"}
    end
  end

  defp generate_handle_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp encode_error(type, message) do
    Jason.encode!(%{
      "error" => %{
        "type" => to_string(type),
        "message" => message
      }
    })
  end
end
