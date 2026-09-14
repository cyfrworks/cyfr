# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpStreamHandler do
  @moduledoc """
  Polling-based streaming HTTP handler for WASM components.

  Provides `cyfr:http/streaming` host functions that enable WASM components to
  consume streaming HTTP responses (e.g., Server-Sent Events from OpenAI).

  ## Interface

      cyfr:http/streaming.request(json) -> handle_id (string)
      cyfr:http/streaming.read(handle_id) -> chunk_json (string)
      cyfr:http/streaming.close(handle_id) -> result (string)

  ## Flow

  1. WASM calls `stream.request(json)` — host starts async HTTP request, returns handle ID
  2. WASM calls `stream.read(handle)` in a loop — returns `{"data": "...", "done": false,
     "status": 200}`, `status` being the provider's HTTP status once its response began.
     A read waits up to 100 ms for a chunk and answers `"data": ""` when none arrived.
  3. When stream ends: `{"data": "", "done": true, "status": 200}`
  4. WASM calls `stream.close(handle)` — host cleans up resources

  A request that fails before a response, a stream that stops arriving
  for the node's timeout, and a transport error each answer the read
  after the last buffered chunk with `{"error": {"type", "message"}}`
  (`request_failed`, `timeout`, `stream_error`).

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
  alias Cyfr.Limits
  alias Opus.{HttpHandler, HttpRequestValidation}

  # Fallback stream timeout, used only when the node limits carry an
  # unparseable duration (limits are validated when the blob parses).
  @stream_timeout_ms 60_000

  # The cache entry must outlive the stream timeout so the timeout branch in
  # stream_read/3 — which stops the collector process and buffer agent — runs
  # instead of a bare cache expiry that would strand them.
  @stream_ttl_grace_ms 5_000

  # How long a read waits for a chunk before answering empty, and how often
  # it looks while it waits.
  @read_wait_ms 100
  @read_poll_ms 5

  # Fixed cap on open stream handles per execution. Deliberately not derived
  # from Limits.max_concurrent_tasks: that limit governs concurrent task
  # execution, not open response handles.
  @max_concurrent_streams 3

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:http/streaming` host functions.

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
             guarded(component_ref, "request", fn ->
               stream_request(json_req, edge, limits, ctx, component_ref, exec_ref)
             end)
           end},
        "read" =>
          {:fn,
           fn handle_id ->
             guarded(component_ref, "read", fn ->
               stream_read(handle_id, exec_ref, limits)
             end)
           end},
        "close" =>
          {:fn,
           fn handle_id ->
             guarded(component_ref, "close", fn ->
               stream_close(handle_id, exec_ref)
             end)
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

  # Catch host-function failures and return stream_error to the guest.
  # Keep fault details in the host log.
  defp guarded(component_ref, name, fun) do
    fun.()
  rescue
    exception ->
      Logger.error(
        "[Opus.HttpStreamHandler] #{component_ref} #{name} raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      encode_error(:stream_error, "The streaming request could not be served.")
  catch
    # A refusal `start_stream/4` could not answer in place — the buffer or the
    # supervised task would not start. Thrown rather than raised so the reason
    # reaches the log intact.
    {:stream_start_failed, what, reason} ->
      Logger.error(
        "[Opus.HttpStreamHandler] #{component_ref} could not start a stream " <>
          "(#{what}): #{inspect(reason)}"
      )

      encode_error(:stream_error, "The streaming request could not be started.")

    :exit, reason ->
      Logger.error("[Opus.HttpStreamHandler] #{component_ref} #{name} exited: #{inspect(reason)}")

      encode_error(:stream_error, "The streaming request could not be served.")
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

    # Create a buffer agent to collect chunks. A :queue keeps both ends O(1):
    # the byte ceiling bounds total size but not chunk count, and an SSE
    # stream of many small frames would pay O(n²) on a plain list append.
    #
    # Deliberately LINKED to the calling Wasmex host process — unlike the
    # streaming task below — because the link is what reaps the buffer when
    # the executor brutal-kills the runtime at timeout; an Agent exits only
    # abnormally if its own anonymous fn raises, which none here can.
    buffer =
      case Agent.start_link(fn ->
             %{chunks: :queue.new(), done: false, total_bytes: 0, error: nil, status: nil}
           end) do
        {:ok, pid} -> pid
        {:error, reason} -> throw({:stream_start_failed, :buffer, reason})
      end

    # Start an unlinked but SUPERVISED process for the streaming request:
    # Task.Supervisor.start_child links the task to the supervisor, not to
    # this caller — the Wasmex.Components GenServer must receive neither a
    # Task.async completion message nor a spawn_link EXIT signal (both
    # unhandled by Wasmex), and a bare spawn left the request outside every
    # tree at shutdown.
    # Carry the tenant correlators into the task — the one spawn in the
    # tree that skipped the capture/restore convention, so guest streaming
    # logs arrived with no athanor_id or execution_id.
    logger_metadata = Cyfr.LoggerContext.capture()

    start =
      Task.Supervisor.start_child(Opus.TaskSupervisor, fn ->
        Cyfr.LoggerContext.restore(logger_metadata)

        try do
          perform_streaming_request(request, buffer, component_ref, timeout_ms, max_response_size)
        rescue
          e ->
            Logger.warning(
              "[Opus.HttpStreamHandler] Streaming request crashed: #{Exception.message(e)}"
            )

            park_error(buffer, :stream_error, "The streaming request failed.")
        after
          update_buffer(buffer, &%{&1 | done: true})
        end
      end)

    # `start_child/2` ANSWERS `{:error, …}` — a supervisor mid-restart, or at
    # its child ceiling — so the refusal is read, not matched. The buffer this
    # stream already opened goes with it; nothing else will reap it, since the
    # link that would have is to a task that never started.
    pid =
      case start do
        {:ok, pid} ->
          pid

        {:error, reason} ->
          Agent.stop(buffer, :normal)
          throw({:stream_start_failed, :task, reason})
      end

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

  defp perform_streaming_request(request, buffer, component_ref, timeout_ms, max_response_size) do
    # The pinned URL and transport policy come from `Cyfr.Network.pin/2`
    # via validation — same seam as the buffered fetch path.
    req_opts =
      request.pin_req_opts
      |> Keyword.put(:method, request.method_atom)
      |> Keyword.put(:headers, request.headers)
      |> Keyword.put(:receive_timeout, timeout_ms)
      |> Keyword.put(:into, :self)
      |> then(fn opts ->
        if request.body != "", do: Keyword.put(opts, :body, request.body), else: opts
      end)

    start_time = System.monotonic_time(:millisecond)

    case Req.request(req_opts) do
      {:ok, response} ->
        update_buffer(buffer, &%{&1 | status: response.status})

        # The stream path emits the same [:cyfr, :opus, :http, :request]
        # event the fetch path always did — it emitted nothing before, so
        # streamed egress was invisible to telemetry.
        HttpHandler.emit_telemetry(
          component_ref,
          request,
          response.status,
          System.monotonic_time(:millisecond) - start_time
        )

        # Collect streaming chunks
        collect_stream_chunks(response, buffer, timeout_ms, max_response_size)

      {:error, exception} ->
        HttpHandler.emit_telemetry(
          component_ref,
          request,
          :error,
          System.monotonic_time(:millisecond) - start_time
        )

        park_error(buffer, :request_failed, Exception.message(exception))
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
                update_buffer(buffer, &%{&1 | done: true})

              _other ->
                :ok
            end)

            cond do
              # Over budget or closed: stop collecting; this process exiting
              # closes the connection, and stream_read surfaces a parked error.
              stopped?(buffer) ->
                :ok

              Enum.member?(chunks, :done) ->
                :ok

              true ->
                collect_stream_chunks(response, buffer, timeout_ms, max_response_size)
            end

          {:error, reason} ->
            park_error(buffer, :stream_error, "The stream broke: #{inspect(reason)}")
            :error

          :unknown ->
            # Message not for this response, keep waiting
            collect_stream_chunks(response, buffer, timeout_ms, max_response_size)
        end
    after
      timeout_ms ->
        park_error(buffer, :timeout, "No stream data for #{div(timeout_ms, 1000)}s")
        :timeout
    end
  end

  # The first error parked stands; the stream is done either way.
  defp park_error(buffer, type, message) do
    update_buffer(buffer, fn
      %{error: nil} = state -> %{state | done: true, error: {type, message}}
      state -> %{state | done: true}
    end)
  end

  defp stopped?(buffer) do
    Agent.get(buffer, & &1.error) != nil
  catch
    :exit, _ -> true
  end

  # A buffer a close already stopped has no reader left to tell.
  defp update_buffer(buffer, fun) do
    Agent.update(buffer, fun)
  catch
    :exit, _ -> :ok
  end

  # Append-time budget: the collector runs ahead of the guest's reads, so an
  # unread stream must never buffer more than the consented max_response_size.
  # The overflowing chunk is dropped, the error is parked in the buffer, and
  # stream_read surfaces it (same shape as the read-path debit) once the
  # already-buffered chunks drain.
  defp append_chunk(buffer, data, max_response_size) do
    update_buffer(buffer, fn
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
          %{state | chunks: :queue.in(data, state.chunks), total_bytes: new_total}
        end
    end)
  end

  defp read_from_stream(handle_id, stream_state, exec_ref, limits) do
    deadline = System.monotonic_time(:millisecond) + @read_wait_ms

    case next_chunk(stream_state.buffer, deadline) do
      {:empty, _done, {type, message}, _status} ->
        cleanup_stream(stream_state)
        Arca.Cache.invalidate({:http_stream, exec_ref, handle_id})
        encode_error(type, message)

      {:empty, done, nil, status} ->
        read_answer("", done, status)

      {:chunk, chunk, status} ->
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

          read_answer(chunk, false, status)
        end
    end
  end

  # Pop the first chunk atomically, so the collector cannot append between
  # a look and a take; an empty, open stream is looked at again until
  # `deadline`.
  defp next_chunk(buffer, deadline) do
    popped =
      Agent.get_and_update(buffer, fn state ->
        case :queue.out(state.chunks) do
          {{:value, chunk}, rest} -> {{:chunk, chunk, state.status}, %{state | chunks: rest}}
          {:empty, _} -> {{:empty, state.done, state.error, state.status}, state}
        end
      end)

    case popped do
      {:empty, false, nil, _status} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@read_poll_ms)
          next_chunk(buffer, deadline)
        else
          popped
        end

      _ ->
        popped
    end
  end

  defp read_answer(data, done, nil), do: safe_encode(%{"data" => data, "done" => done})

  defp read_answer(data, done, status),
    do: safe_encode(%{"data" => data, "done" => done, "status" => status})

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
