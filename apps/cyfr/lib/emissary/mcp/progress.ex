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

  Channels are keyed on `context.request_id`, which is minted per request, so
  a channel belongs to exactly one call. A key that was stable per credential
  would hand two concurrent calls by the same caller a shared channel, and
  each would receive the other's progress.

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
