# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

  All the same edge enforcement as `cyfr:http/fetch` applies — both handlers
  go through `Opus.HttpRequestValidation`, the single pre-flight path:
  - Domain/method/scheme allowlisting, SSRF prevention with IP pinning
  - Request body checked against the node's `max_request_size`
  - Response bytes capped at `max_response_size` both when the collector
    buffers them and when the guest reads them
  - Stream timeout comes from the node's consented `timeout` limit
    (60s fallback only when the limits carry an unparseable duration)
  - Max concurrent streams per execution (fixed at 3)
  - Auto-cleanup on timeout or on execution completion
  """

  require Logger

  alias Sanctum.Authority.Blob.Edge
  alias Sanctum.Context
  alias Sanctum.Limits
  alias Opus.{HttpHandler, HttpRequestValidation}

  # Fallback stream timeout, used only when the node limits carry an
  # unparseable duration (limits are validated when the blob parses).
  @stream_timeout_ms 60_000

  # The cache entry must outlive the stream timeout so the timeout branch in
  # stream_read/3 — which stops the collector process and buffer agent — runs
  # instead of a bare cache expiry that would strand them.
  @stream_ttl_grace_ms 5_000

  # Fixed cap on open stream handles per execution. Deliberately not derived
  # from Limits.max_concurrent_tasks: that limit governs concurrent task
  # execution, not open response handles.
  @max_concurrent_streams 3

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:http/stream` host functions.

  Returns a map with `request`, `read`, and `close` functions.
  """
  @spec build_stream_imports(Edge.t() | nil, Limits.t(), Context.t(), String.t()) ::
          {map(), String.t()}
  def build_stream_imports(edge, %Limits{} = limits, %Context{} = ctx, component_ref) do
    # Create a unique execution ref for cache-based stream tracking
    exec_ref = create_registry()

    imports = %{
      "cyfr:http/streaming@0.1.0" => %{
        "request" =>
          {:fn,
           fn json_req ->
             stream_request(json_req, edge, limits, ctx, component_ref, exec_ref)
           end},
        "read" =>
          {:fn,
           fn handle_id ->
             stream_read(handle_id, exec_ref, limits)
           end},
        "close" =>
          {:fn,
           fn handle_id ->
             stream_close(handle_id, exec_ref)
           end}
      }
    }

    {imports, exec_ref}
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

  defp stream_request(json_request, edge, limits, ctx, component_ref, exec_ref) do
    # Check concurrent stream limit
    stream_count =
      Arca.Cache.match({:http_stream, exec_ref, :_})
      |> length()

    if stream_count >= @max_concurrent_streams do
      encode_error(
        :stream_limit,
        "Maximum concurrent streams (#{@max_concurrent_streams}) exceeded"
      )
    else
      case HttpRequestValidation.validate(json_request, edge, limits, ctx, component_ref,
             allow_multipart: false
           ) do
        {:ok, request} ->
          start_stream(request, exec_ref, component_ref, limits)

        {:error, type, message} ->
          HttpHandler.record_egress_denial(ctx, component_ref, type, message)
          encode_error(type, message)
      end
    end
  end

  defp stream_read(handle_id, exec_ref, limits) do
    case Arca.Cache.get({:http_stream, exec_ref, handle_id}) do
      {:ok, stream_state} ->
        # Check timeout
        elapsed = System.monotonic_time(:millisecond) - stream_state.started_at

        if elapsed > stream_state.timeout_ms do
          cleanup_stream(stream_state)
          Arca.Cache.invalidate({:http_stream, exec_ref, handle_id})
          encode_error(:timeout, "Stream timed out after #{div(stream_state.timeout_ms, 1000)}s")
        else
          read_from_stream(handle_id, stream_state, exec_ref, limits)
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
        safe_encode(%{"ok" => true})

      :miss ->
        safe_encode(%{"ok" => true})
    end
  end

  # ============================================================================
  # Private: Stream Lifecycle
  # ============================================================================

  defp start_stream(request, exec_ref, component_ref, limits) do
    handle_id = generate_handle_id()
    timeout_ms = HttpRequestValidation.timeout_ms(limits, @stream_timeout_ms)
    max_response_size = limits.max_response_size

    # Create a buffer agent to collect chunks
    {:ok, buffer} =
      Agent.start_link(fn -> %{chunks: [], done: false, total_bytes: 0, error: nil} end)

    # Start an unlinked process to perform the streaming request.
    # NOTE: We use spawn (not Task.async or spawn_link) because this code
    # runs inside the Wasmex.Components GenServer. Task.async sends a
    # completion message that crashes handle_info/2, and spawn_link sends
    # an EXIT signal on process termination — both unhandled by Wasmex.
    pid =
      spawn(fn ->
        try do
          perform_streaming_request(request, buffer, component_ref, timeout_ms, max_response_size)
        rescue
          e ->
            Logger.warning(
              "[Opus.HttpStreamHandler] Streaming request crashed: #{Exception.message(e)}"
            )
        after
          try do
            Agent.update(buffer, fn state -> %{state | done: true} end)
          rescue
            ArgumentError -> :ok
          catch
            :exit, _ -> :ok
          end
        end
      end)

    stream_state = %{
      task_pid: pid,
      buffer: buffer,
      started_at: System.monotonic_time(:millisecond),
      cumulative_size: 0,
      component_ref: component_ref,
      timeout_ms: timeout_ms
    }

    Arca.Cache.put(
      {:http_stream, exec_ref, handle_id},
      stream_state,
      timeout_ms + @stream_ttl_grace_ms
    )

    safe_encode(%{"handle" => handle_id})
  end

  defp perform_streaming_request(request, buffer, _component_ref, timeout_ms, max_response_size) do
    # Pin the connection to the IP validated by HttpRequestValidation by
    # substituting it for the hostname, while preserving the original hostname
    # for TLS SNI / certificate verification / the Host header (Mint's
    # :hostname connect option). This closes the DNS-rebinding TOCTOU gap that
    # re-resolving request.url would reopen; preserving SNI/Host keeps CDN
    # routing working (CDNs only reject bare-IP connections that drop SNI).
    # Mirrors HttpHandler.build_req_opts/2.
    uri = URI.parse(request.url)
    pinned_url = URI.to_string(%{uri | host: Cyfr.Network.bracket_ip(request.ip)})

    req_opts = [
      method: request.method_atom,
      url: pinned_url,
      headers: request.headers,
      body: if(request.body != "", do: request.body, else: nil),
      redirect: false,
      receive_timeout: timeout_ms,
      connect_options: [hostname: uri.host, protocols: [:http1]],
      into: :self
    ]

    case Req.request(req_opts) do
      {:ok, response} ->
        # Collect streaming chunks
        collect_stream_chunks(response, buffer, timeout_ms, max_response_size)

      {:error, _exception} ->
        Agent.update(buffer, fn state -> %{state | done: true} end)
    end
  end

  defp collect_stream_chunks(response, buffer, timeout_ms, max_response_size) do
    # Req's `into: :self` sends raw Mint transport messages (e.g. {:ssl, socket, data}).
    # We must use Req.parse_message/2 to decode them into {:ok, chunks} where
    # chunks contain {:data, binary} or :done.
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, chunks} ->
            Enum.each(chunks, fn
              {:data, data} ->
                append_chunk(buffer, data, max_response_size)

              :done ->
                Agent.update(buffer, fn state -> %{state | done: true} end)

              _other ->
                :ok
            end)

            cond do
              # Over budget: stop collecting; this process exiting closes the
              # connection, and stream_read surfaces the parked error.
              Agent.get(buffer, & &1.error) != nil ->
                :ok

              Enum.member?(chunks, :done) ->
                :ok

              true ->
                collect_stream_chunks(response, buffer, timeout_ms, max_response_size)
            end

          {:error, _reason} ->
            Agent.update(buffer, fn state -> %{state | done: true} end)
            :error

          :unknown ->
            # Message not for this response, keep waiting
            collect_stream_chunks(response, buffer, timeout_ms, max_response_size)
        end
    after
      timeout_ms ->
        Agent.update(buffer, fn state -> %{state | done: true} end)
        :timeout
    end
  end

  # Append-time budget: the collector runs ahead of the guest's reads, so an
  # unread stream must never buffer more than the consented max_response_size.
  # The overflowing chunk is dropped, the error is parked in the buffer, and
  # stream_read surfaces it (same shape as the read-path debit) once the
  # already-buffered chunks drain.
  defp append_chunk(buffer, data, max_response_size) do
    Agent.update(buffer, fn
      %{error: error} = state when not is_nil(error) ->
        state

      state ->
        new_total = state.total_bytes + byte_size(data)

        if new_total > max_response_size do
          %{
            state
            | done: true,
              error:
                {:response_too_large,
                 "Stream response (#{new_total} bytes) exceeds limit (#{max_response_size} bytes)"}
          }
        else
          %{state | chunks: state.chunks ++ [data], total_bytes: new_total}
        end
    end)
  end

  defp read_from_stream(handle_id, stream_state, exec_ref, limits) do
    # Atomically pop the first chunk to avoid race with the streaming process
    # appending new chunks between a get and a separate update.
    case Agent.get_and_update(stream_state.buffer, fn state ->
           case state.chunks do
             [chunk | rest] -> {{:chunk, chunk}, %{state | chunks: rest}}
             [] -> {{:empty, state.done, state.error}, state}
           end
         end) do
      {:empty, _done, {type, message}} ->
        cleanup_stream(stream_state)
        Arca.Cache.invalidate({:http_stream, exec_ref, handle_id})
        encode_error(type, message)

      {:empty, true, nil} ->
        safe_encode(%{"data" => "", "done" => true})

      {:empty, false, nil} ->
        safe_encode(%{"data" => "", "done" => false})

      {:chunk, chunk} ->
        # Track cumulative response size
        new_cumulative = stream_state.cumulative_size + byte_size(chunk)

        if new_cumulative > limits.max_response_size do
          cleanup_stream(stream_state)
          Arca.Cache.invalidate({:http_stream, exec_ref, handle_id})

          encode_error(
            :response_too_large,
            "Stream response (#{new_cumulative} bytes) exceeds limit (#{limits.max_response_size} bytes)"
          )
        else
          # Update cumulative size in cache
          updated_state = %{stream_state | cumulative_size: new_cumulative}

          Arca.Cache.put(
            {:http_stream, exec_ref, handle_id},
            updated_state,
            stream_state.timeout_ms + @stream_ttl_grace_ms
          )

          safe_encode(%{"data" => chunk, "done" => false})
        end
    end
  end

  defp cleanup_stream(stream_state) do
    # Stop the buffer agent
    try do
      Agent.stop(stream_state.buffer, :normal)
    rescue
      e in [ArgumentError, RuntimeError] ->
        Logger.warning(
          "[Opus.HttpStreamHandler] Failed to stop buffer agent: #{Exception.message(e)}"
        )

        :ok
    catch
      :exit, _ -> :ok
    end

    # Kill the streaming process if still running
    if is_pid(stream_state[:task_pid]) and Process.alive?(stream_state.task_pid) do
      Process.exit(stream_state.task_pid, :kill)
    end
  end

  defp generate_handle_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp safe_encode(data), do: Opus.WitResponse.safe_encode(data)

  defp encode_error(type, message), do: Opus.WitResponse.encode_error(type, message)
end
