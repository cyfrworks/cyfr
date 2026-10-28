# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Handle do
  @moduledoc """
  A handle at the registry, resolved to the identifier it names
  (`Prima.HandleAnswer`, `cyfr-handle/v1`).

  The answer is navigation, never authority: it names an identifier, the
  directory that orders it and the address its owner published, if any,
  and carries no keys. Whoever relies on the identifier reads its keys
  fresh from that directory (`Sanctum.IdentityFreshness`), so a handle
  the registry later reassigns moves no access.

  `resolve/1` asks `GET /v1/handles/{handle}` of the registry this
  deployment names (`Sanctum.registry_host/0`), for that one exact handle:
  there is no listing or search. The request goes through
  `Sanctum.Egress.pinned_request/5` under `private_policy: :operator`, is
  bounded to 10 seconds and 16 KiB, follows no redirect, sends no
  credential, and nothing is cached.

  Refusals: `:invalid_handle` (a spelling `Prima.ComponentRef` refuses as
  a personal slug, before any request), `:no_registry` (before any
  request), `:not_found` (no one holds the handle, a reserved one
  included), `:registry_unavailable` (unreachable, slow, refused by the
  address policy, or any answer but the two above) and
  `:malformed_answer` (an answer for another handle or registry, or
  outside its grammar).
  """

  require Logger

  alias Prima.HandleAnswer

  @request_ms 10_000
  @response_bytes 16_384

  @type reason ::
          :invalid_handle | :no_registry | :not_found | :registry_unavailable | :malformed_answer

  @doc "Resolve `handle` at this deployment's registry (the module doc)."
  @spec resolve(String.t()) :: {:ok, HandleAnswer.t()} | {:error, reason()}
  def resolve(handle) when is_binary(handle) do
    with :ok <- spelled(handle),
         {:ok, registry} <- Sanctum.registry_host() do
      url =
        Sanctum.registry_base_url(Sanctum.registry_url()) <>
          "/v1/handles/" <> URI.encode(handle, &URI.char_unreserved?/1)

      url |> fetch() |> answer(handle, registry)
    end
  end

  def resolve(_handle), do: {:error, :invalid_handle}

  @doc """
  The identifier `handle` names, for a write that keeps the identifier and
  never the handle (an allowlist entry, a membership): `resolve/1`, its
  refusals as the writer answers them. A spelling the slug grammar refuses
  is an invalid argument that says what a handle is; no one holding the
  handle is `:handle_not_found`; an unreadable answer is
  `:registry_unavailable`, as an unreachable registry is. It writes
  nothing, so a caller that resolves first and writes after leaves no row
  when it stops between the two.
  """
  @spec identifier(String.t()) ::
          {:ok, String.t()}
          | {:error,
             {:invalid_argument, String.t()}
             | :no_registry
             | :handle_not_found
             | :registry_unavailable}
  def identifier(handle) do
    case resolve(handle) do
      {:ok, %HandleAnswer{identifier: identifier}} ->
        {:ok, identifier}

      {:error, :invalid_handle} ->
        {:error,
         {:invalid_argument,
          "That is not a handle: a handle is lowercase letters, digits and single hyphens, " <>
            "at most 39 characters"}}

      {:error, :not_found} ->
        {:error, :handle_not_found}

      {:error, :malformed_answer} ->
        {:error, :registry_unavailable}

      {:error, reason} when reason in [:no_registry, :registry_unavailable] ->
        {:error, reason}
    end
  end

  defp spelled(handle) do
    if Prima.ComponentRef.valid_personal_slug?(handle),
      do: :ok,
      else: {:error, :invalid_handle}
  end

  # The request runs in a task linked to the caller, so it stops with the
  # caller, and the yield bounds it even against a registry that answers a
  # byte at a time.
  defp fetch(url) do
    task =
      Task.Supervisor.async(Sanctum.TaskSupervisor, fn ->
        try do
          Sanctum.Egress.pinned_request(
            :get,
            url,
            [{"accept", "application/json"}, {"user-agent", "CYFR/" <> Prima.Version.current()}],
            nil,
            private_policy: :operator,
            receive_timeout: @request_ms,
            max_response_bytes: @response_bytes
          )
        rescue
          exception -> {:error, {:raised, exception.__struct__}}
        end
      end)

    case Task.yield(task, @request_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timed_out -> {:error, :timeout}
    end
  end

  defp answer({:ok, 200, _headers, body}, handle, registry) do
    case HandleAnswer.parse(body, handle, registry) do
      {:ok, answer} -> {:ok, answer}
      {:error, :handle_not_found} -> {:error, :not_found}
      {:error, _malformed} -> {:error, :malformed_answer}
    end
  end

  defp answer({:ok, 404, _headers, _body}, _handle, _registry), do: {:error, :not_found}

  defp answer({:ok, status, _headers, _body}, _handle, _registry) do
    Logger.warning("[Sanctum.Handle] the registry answered a handle with HTTP #{status}")
    {:error, :registry_unavailable}
  end

  defp answer({:error, reason}, _handle, _registry) do
    Logger.warning(
      "[Sanctum.Handle] a handle request failed: " <> Prima.LoggerContext.shape(reason)
    )

    {:error, :registry_unavailable}
  end
end
