# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RequestLog do
  @moduledoc """
  MCP call logging for CYFR.

  One row per call, so a chain is legible: the `execution.run` an ingress
  received, and each tool the running component reached from inside the
  sandbox. `id` is the call, `request_id` is the ingress request they share.

  In-chain calls have their own log rows and share the root request id.

  Routes all persistent storage through `Arca.McpLog`. The start of a call
  is written synchronously (the row must exist); its completion or failure
  goes through `Arca.RecordSink`, the write-behind.

  Every row is filed under the athanor the call ran in. A call with no
  athanor on its context — the anonymous surface (`initialize`,
  `tools/list`, `system.status` before sign-in) — has no tenant to be filed
  under and is not recorded here; it is still rate-limited and traced by the
  request logger. A public tincture's calls carry the tincture's athanor.

  ## Sensitive Data

  Input parameters are automatically sanitized to redact passwords,
  secrets, tokens, and API keys before logging.
  """

  alias Sanctum.Context

  require Logger

  @type log_entry :: %{
          call_id: String.t(),
          request_id: String.t() | nil,
          user_id: String.t(),
          timestamp: String.t(),
          tool: String.t() | nil,
          action: String.t() | nil,
          method: String.t() | nil,
          input: map(),
          output: map() | nil,
          status: String.t(),
          duration_ms: non_neg_integer() | nil,
          routed_to: String.t() | nil,
          error: String.t() | nil,
          error_code: integer() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Log the start of one call.

  `call_id` identifies this call; `ctx.request_id` identifies the ingress
  request it belongs to, which is what groups a chain. For the request an
  ingress received the two are the same value — it is its own root.

  Called before the work runs, so the row exists with status "pending" even if
  the process dies. Input is automatically sanitized.
  """
  @spec log_started(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def log_started(%Context{athanor_id: athanor_id}, _call_id, _data)
      when athanor_id in [nil, ""],
      do: :ok

  def log_started(%Context{} = ctx, call_id, data)
      when is_binary(call_id) and is_map(data) do
    case Arca.McpLog.record(started_row(ctx, call_id, data)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp started_row(%Context{} = ctx, call_id, data) do
    %{
      id: call_id,
      request_id: ctx.request_id,
      user_id: ctx.user_id || "system",
      athanor_id: ctx.athanor_id,
      timestamp: DateTime.utc_now(),
      tool: data[:tool] || data["tool"],
      action: data[:action] || data["action"],
      method: data[:method] || data["method"],
      status: "pending",
      input: encode_json(sanitize_input(data[:input] || data["input"] || %{}))
    }
  end

  @doc """
  Log successful completion of an MCP request.
  """
  @spec log_completed(Context.t(), String.t(), map()) :: :ok
  def log_completed(%Context{athanor_id: athanor_id}, _call_id, _data)
      when athanor_id in [nil, ""],
      do: :ok

  def log_completed(%Context{} = ctx, call_id, data)
      when is_binary(call_id) and is_map(data) do
    # The row was started synchronously; its completion is bookkeeping and
    # rides the write-behind.
    Arca.RecordSink.enqueue(
      {:mcp_log_update, Context.actor(ctx), call_id,
       %{
         status: "success",
         duration_ms: data[:duration_ms] || data["duration_ms"],
         routed_to: data[:routed_to] || data["routed_to"],
         output: encode_json(sanitize_output(data[:output] || data["output"]))
       }}
    )
  end

  @doc """
  Log failure of an MCP request.
  """
  @spec log_failed(Context.t(), String.t(), map()) :: :ok
  def log_failed(%Context{athanor_id: athanor_id}, _call_id, _data)
      when athanor_id in [nil, ""],
      do: :ok

  def log_failed(%Context{} = ctx, call_id, data)
      when is_binary(call_id) and is_map(data) do
    Arca.RecordSink.enqueue(
      {:mcp_log_update, Context.actor(ctx), call_id,
       %{
         status: "error",
         error_code: data[:code] || data["code"],
         duration_ms: data[:duration_ms] || data["duration_ms"],
         error: sanitize_input(data[:error] || data["error"]),
         routed_to: data[:routed_to] || data["routed_to"]
       }}
    )
  end

  # ============================================================================
  # Best-effort wrappers
  # ============================================================================

  # Logging must never raise, never block, and never fail the underlying
  # operation. Every logging ingress — MCPController, TinctureController,
  # WebhookController, CronScheduler, and the tool dispatch through
  # `around/5` — wants the same contract; centralize it here.

  @doc """
  Record one call around the work that is the call.

  Logs the started row, runs `fun`, and logs the completed or failed row
  with the measured duration — through the `safe_log_*` wrappers, so a
  logging fault never fails the call. `fun` returns `{result, meta}`:
  `meta[:routed_to]` labels the row when present, `meta[:code]` overrides
  the default `-32_603` failure code, and `meta[:error_text]` supplies an
  already-formatted error string in place of the sanitized `inspect`.
  Returns `result`. With `log?` false, runs `fun` and only returns.
  """
  @spec around(false | true | :behind, Context.t(), String.t() | nil, map(), (-> {result, map()})) ::
          result
        when result: {:ok, term()} | {:error, term()}
  def around(log?, ctx, call_id, started, fun)

  def around(false, _ctx, _call_id, _started, fun) do
    {result, _meta} = fun.()
    result
  end

  # The row's start rides the write-behind as well as its close: an
  # in-process call is its own root and nothing reads its row before it
  # ends. The close carries the whole row, so a start that was shed, or
  # lands late, leaves one complete row either way.
  def around(:behind, %Context{athanor_id: athanor_id} = ctx, call_id, started, fun)
      when is_binary(athanor_id) and is_binary(call_id) do
    row = started_row(ctx, call_id, started)
    safe_enqueue({:mcp_log_started, row})
    start_time = System.monotonic_time()
    {result, meta} = fun.()

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    close =
      case result do
        {:ok, output} ->
          put_routed(
            %{
              status: "success",
              duration_ms: duration_ms,
              output: encode_json(sanitize_output(output))
            },
            meta
          )

        {:error, reason} ->
          error_text = Map.get(meta, :error_text) || inspect(sanitize_input(reason))

          put_routed(
            %{
              status: "error",
              error_code: Map.get(meta, :code, -32_603),
              duration_ms: duration_ms,
              error: error_text
            },
            meta
          )
      end

    safe_enqueue({:mcp_log_close, row, close})
    result
  end

  def around(:behind, ctx, call_id, started, fun),
    do: around(true, ctx, call_id, started, fun)

  def around(true, %Context{} = ctx, call_id, started, fun) do
    safe_log_started(ctx, call_id, started)
    start_time = System.monotonic_time()
    {result, meta} = fun.()

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    case result do
      {:ok, output} ->
        safe_log_completed(
          ctx,
          call_id,
          put_routed(%{output: output, duration_ms: duration_ms}, meta)
        )

      {:error, reason} ->
        error_text = Map.get(meta, :error_text) || inspect(sanitize_input(reason))

        safe_log_failed(
          ctx,
          call_id,
          put_routed(
            %{error: error_text, code: Map.get(meta, :code, -32_603), duration_ms: duration_ms},
            meta
          )
        )
    end

    result
  end

  # The write-behind never fails the call either: inline (the test env)
  # it writes in the caller, and a caller with no connection of its own
  # loses the row, as it would have under the synchronous start.
  #
  # A store that goes away does not raise, it exits — `DBConnection` exits
  # the caller when its connection dies, and under the test sandbox that
  # happens whenever the owning process finishes first. `rescue` alone left
  # that exit to travel into the call this is supposed to never fail.
  defp safe_enqueue(item) do
    Arca.RecordSink.enqueue(item)
  rescue
    e -> Logger.warning("[RequestLog] log row not queued: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("[RequestLog] log row not queued: store exited #{inspect(reason)}")
  end

  defp put_routed(data, %{routed_to: routed}) when not is_nil(routed),
    do: Map.put(data, :routed_to, routed)

  defp put_routed(data, _meta), do: data

  @doc """
  Best-effort wrapper around `log_started/3`. Always returns `:ok`.

  Logs unexpected errors via `Logger.error` rather than propagating.
  """
  @spec safe_log_started(Context.t(), String.t(), map()) :: :ok
  def safe_log_started(%Context{} = ctx, call_id, data) do
    case log_started(ctx, call_id, data) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[RequestLog] log_started failed for #{call_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.error("[RequestLog] log_started raised for #{call_id}: #{Exception.message(e)}")
      :ok
  catch
    # "Always returns :ok" has to cover an exit too: a store whose
    # connection dies exits its caller rather than raising.
    :exit, reason ->
      Logger.error("[RequestLog] log_started exited for #{call_id}: #{inspect(reason)}")
      :ok
  end

  @doc """
  Best-effort wrapper around `log_completed/3`. Always returns `:ok`.
  """
  @spec safe_log_completed(Context.t(), String.t(), map()) :: :ok
  def safe_log_completed(%Context{} = ctx, call_id, data) do
    log_completed(ctx, call_id, data)
  rescue
    e ->
      Logger.error("[RequestLog] log_completed raised for #{call_id}: #{Exception.message(e)}")
      :ok
  catch
    # "Always returns :ok" has to cover an exit too: a store whose
    # connection dies exits its caller rather than raising.
    :exit, reason ->
      Logger.error("[RequestLog] log_completed exited for #{call_id}: #{inspect(reason)}")
      :ok
  end

  @doc """
  Best-effort wrapper around `log_failed/3`. Always returns `:ok`.
  """
  @spec safe_log_failed(Context.t(), String.t(), map()) :: :ok
  def safe_log_failed(%Context{} = ctx, call_id, data) do
    log_failed(ctx, call_id, data)
  rescue
    e ->
      Logger.error("[RequestLog] log_failed raised for #{call_id}: #{Exception.message(e)}")
      :ok
  catch
    # "Always returns :ok" has to cover an exit too: a store whose
    # connection dies exits its caller rather than raising.
    :exit, reason ->
      Logger.error("[RequestLog] log_failed exited for #{call_id}: #{inspect(reason)}")
      :ok
  end

  # ============================================================================
  # Input Sanitization
  # ============================================================================

  @doc """
  Sanitize input data to redact sensitive values.

  Delegates to `Cyfr.Sanitizer.sanitize/1`.
  """
  @spec sanitize_input(term()) :: term()
  defdelegate sanitize_input(input), to: Cyfr.Sanitizer, as: :sanitize

  # The tools/call wire shape re-encodes the tool's structured result as an
  # opaque JSON string under `"content"[]."text"`. Key-based redaction cannot
  # see inside a string, so a credential a tool legitimately returns to its
  # caller (a created API key, a webhook secret, a session token) would be
  # persisted verbatim. Decode each text block that parses as JSON, sanitize
  # the structure, and re-encode; prose text passes through untouched. The
  # client response is built before logging and is never affected.
  defp sanitize_output(nil), do: nil

  defp sanitize_output(%{"content" => blocks} = output) when is_list(blocks) do
    %{output | "content" => Enum.map(blocks, &sanitize_text_block/1)}
    |> sanitize_input()
  end

  defp sanitize_output(output), do: sanitize_input(output)

  defp sanitize_text_block(%{"type" => "text", "text" => text} = block)
       when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        %{block | "text" => Jason.encode!(sanitize_input(decoded))}

      _ ->
        block
    end
  end

  defp sanitize_text_block(block), do: block

  # ============================================================================
  # Private
  # ============================================================================

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_binary(value), do: value

  # Never inspect/1 into a stored column — Elixir term syntax in a JSON
  # field reads as data to every later decoder.
  defp encode_json(value), do: Cyfr.Json.safe_encode(value)
end
