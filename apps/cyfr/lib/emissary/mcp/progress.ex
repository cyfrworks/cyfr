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

  The work publishes each step as a `Cyfr.Bus.Progress` on its subject's
  topic and on its request's (`Cyfr.Bus.progress/2` with
  `{:request, request_id}`); request ids are minted per request, so a request's
  topic belongs to exactly one call. The connection process subscribes to that
  topic before it dispatches, binds the client's token here (`listen/2`), and
  renders each step it hears (`notification/1`). The bus bounds what reaches a
  backed-up connection (`Cyfr.Bus.BoundedDispatcher`).

  ## Contract

  Callers opt in to streaming with `_meta.progressToken`. Without it, the
  server returns one JSON object and no process listens. Lost progress
  notifications must not fail the underlying work.
  """

  require Logger

  alias Cyfr.Bus.Progress, as: Step
  alias Emissary.MCP.Message

  @doc """
  Bind `progress_token` to `request_id` in the calling process — the
  connection that streams the request's response. A request id already
  bound keeps its first token: ids are minted per request, so a second
  bind means one is being reused, and the first stream stays intact.
  """
  @spec listen(String.t(), term()) :: :ok
  def listen(request_id, progress_token) when is_binary(request_id) do
    case Process.get(key(request_id)) do
      nil -> Process.put(key(request_id), progress_token)
      _bound -> Logger.warning("[MCP.Progress] request_id #{request_id} already has a listener")
    end

    :ok
  end

  @doc "Unbind the calling process's token for `request_id`."
  @spec forget(String.t()) :: :ok
  def forget(request_id) when is_binary(request_id) do
    _ = Process.delete(key(request_id))
    :ok
  end

  @doc """
  The `notifications/progress` a step renders to in the calling process:
  the step's phase and message, its subject's id under the key the client
  has always read it by, its data, and the token the client bound. A step
  of a request this process has not bound renders nothing.
  """
  @spec notification(Step.t()) :: {:ok, map()} | :ignore
  def notification(%Step{request_id: request_id} = step) when is_binary(request_id) do
    case Process.get(key(request_id)) do
      nil ->
        :ignore

      token ->
        {kind, id} = step.subject

        params =
          (step.data || %{})
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.merge(%{
            subject_key(kind) => id,
            "phase" => step.phase,
            "message" => step.message,
            "progressToken" => token
          })

        {:ok, Message.encode_notification("notifications/progress", params)}
    end
  end

  def notification(_step), do: :ignore

  defp subject_key(:build), do: "build_id"
  defp subject_key(:register), do: "register_id"
  defp subject_key(:pull), do: "progress_id"

  defp key(request_id), do: {__MODULE__, request_id}
end
