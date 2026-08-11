# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Progress do
  @moduledoc """
  Request-scoped progress notifications.

  A long-running `tools/call` — compiling a component, pulling one from a
  registry — reports progress while it works. In 2026-07-28 those notifications
  travel on the **response stream of the request they belong to**: the server
  answers `text/event-stream`, emits `notifications/progress`, and terminates the
  stream with the response. There is no separate stream to open and nothing to
  correlate by hand.

  ## Why this replaced a buffer keyed by session

  The previous design pushed progress into `Emissary.MCP.SSEBuffer` under
  `context.session_id` and expected the caller to be holding a `GET /mcp` stream
  keyed the same way. Three things were wrong with it, and only the third was a
  conformance problem:

    * **It did not work.** A bearer-authenticated caller's session came from
      `Session.for_credential/2`, which is deliberately never stored, so the
      stream's own liveness check (`Session.exists?/1`) failed and closed it
      after the first keep-alive. Progress for API-key callers — which is every
      CLI user — died 15 seconds in.

    * **The key was too coarse.** `session_id` is stable per credential, so two
      concurrent calls by the same caller shared one channel and each received
      the other's progress.

    * The standalone stream and its `Last-Event-ID` resumption were removed from
      the protocol.

  Keying on `context.request_id` fixes the second point by construction: it is
  minted per request, so a channel belongs to exactly one call.

  ## Contract

  A caller opts in by sending `_meta.progressToken`. Without it the server has no
  permission to stream and answers with a single JSON object — which is why
  `emit/2` is a silent no-op when nobody is registered, rather than an error.
  Progress is a courtesy; losing it must never fail the work.
  """

  require Logger

  alias Emissary.MCP.Message
  alias Sanctum.Context

  @registry __MODULE__.Registry

  @doc "Child spec for the registry that maps a request to its listening connection."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc """
  Register the calling process as the recipient of progress for `request_id`.

  Called by the connection process before it dispatches. The token is stored
  alongside so `emit/2` can stamp it without threading it through every handler.
  """
  @spec listen(String.t(), term()) :: :ok
  def listen(request_id, progress_token) when is_binary(request_id) do
    case Registry.register(@registry, request_id, progress_token) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _}} ->
        # Request ids are minted per request, so this means one is being reused.
        # Refusing to overwrite keeps the first listener's stream intact.
        Logger.warning("[MCP.Progress] request_id #{request_id} already has a listener")
        :ok
    end
  end

  @doc """
  Emit a progress notification for the request `ctx` belongs to.

  `payload` is merged into the notification's params. The `progressToken` the
  client sent is added here rather than by the caller: a handler should not have
  to know how the client opted in, only that it has something to report.
  """
  @spec emit(Context.t(), map()) :: :ok
  def emit(%Context{request_id: request_id}, payload)
      when is_binary(request_id) and is_map(payload) do
    case Registry.lookup(@registry, request_id) do
      [{pid, progress_token}] ->
        params = Map.put(payload, "progressToken", progress_token)
        send(pid, {:mcp_progress, Message.encode_notification("notifications/progress", params)})
        :ok

      [] ->
        # No stream for this request: either the client did not ask for progress,
        # or it hung up. Neither is the working code's problem.
        :ok
    end
  end

  def emit(_ctx, _payload), do: :ok
end
